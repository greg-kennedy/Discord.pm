#!/usr/bin/env perl
package Net::Discord::WSClient;

use strict;
use warnings;

# Module for interacting with the Gateway Websocket servire
# JSON decode
use JSON::PP qw(encode_json decode_json);

# IO::Socket::SSL lets us open encrypted (wss) connections
use IO::Socket::SSL;
# for setting socket timeout
use Socket qw( SOL_SOCKET SO_RCVTIMEO );
# weaken references to parent objects so we don't create circular refs
use Scalar::Util qw(weaken);

# replace time with one that supports microseconds
use Time::HiRes qw( time tv_interval );

# Protocol handler for WebSocket HTTP protocol
use Protocol::WebSocket::Client;
# for testing vs EAGAIN
use Errno;

# better error messages
use Carp;

# debug
use constant DEBUG => 1;

##################################################

use Data::Dumper;

sub new {
  my $class = shift;

  my (%params) = @_;

  # check parameters
  die 'token is required' unless $params{token};
  die 'gateway URL is required' unless $params{url};

  # create class with some params
  my $self = bless { token => $params{token}, url => $params{url} };

  # initialize other params
  $self->{heartbeat_count} = 0;

  # Create a WSS Client object and give it the URL.
  $self->{websocket} = Protocol::WebSocket::Client->new(url => $self->{url} . '/?v=6&encoding=json');

  # This is a hack to make the parent object (us) available to the callback routines.
  $self->{websocket}{owner} = $self;
  weaken $self->{websocket}{owner};

  # Register important callbacks
  $self->{websocket}->on(
    error => sub {
      my $ws = shift;
      my ($buf) = @_;

      croak "Net::Discord::WSClient: Error: WebSocket returned $buf";
    },
    eof => sub {
      my $ws = shift;
      my $code = shift || 0;
      my $reason = shift || 'undef';

      carp "Net::Discord::WSClient: WebSocket connection terminated ($code): $reason";
    },
    write => sub {
      my $ws = shift;
      my ($buf) = @_;

      # just dump encoded content to output
      if (DEBUG) { print "Net::Discord::WSClient: Write " . length($buf) . " bytes\n" }
      syswrite $ws->{owner}->{tcp_socket}, $buf;
    },

    read => sub {
      my $ws = shift;
      my ($buf) = @_;

      # decode the message
      my $response = decode_json($buf);

      if (DEBUG) { print "Net::Discord::WSClient: Read: $buf\n" }

      # record last-seen sequence number
      my $s = $ws->{owner}->advance_sequence($response->{s});

      # call handler based on opcode
      if ($response->{op} == 0)
      {
        if (defined $ws->{owner}{dispatch}) {
          $ws->{owner}{dispatch}->dispatch($response->{t}, $response->{d});
        } else {
          carp "Net::Discord::WSClient: Error: Server sent DISPATCH, but no object registered to handle dispatch events.";
        }
      } elsif ($response->{op} == 1) {
        if (DEBUG) { print "Net::Discord::WSClient: Server requested HEARTBEAT.\n" }
        $ws->{owner}->send_heartbeat();
      } elsif ($response->{op} == 7) {
        if (DEBUG) { print "Net::Discord::WSClient: Server requested RECONNECT.\n" }
        # TODO: we don't handle this so just terminate the connect and maybe the caller will re-join.
        $ws->disconnect();
      } elsif ($response->{op} == 9) {
        if (DEBUG) { print "Net::Discord::WSClient: Server sent INVALID_SESSION.\n" }
        # TODO: we don't handle this so just terminate the connect and maybe the caller will re-join.
        carp "New::Discord::WSClient: Error: Server sent INVALID_SESSION (" . ($response->{d} ? "" : "NOT ") . "resumable)";
        $ws->disconnect();
      } elsif ($response->{op} == 10) {
        if (DEBUG) { print "Net::Discord::WSClient: Server sent HELLO.\n" }

        $ws->{owner}{heartbeat_interval} = $response->{d}{heartbeat_interval} / 1000.0;
        $ws->{owner}{heartbeat_next} = time() + $ws->{owner}{heartbeat_interval};
        # send login message
        $ws->{owner}->send_identify();

      } elsif ($response->{op} == 11) {
        if (DEBUG) { print "Net::Discord::WSClient: Server sent HEARTBEAT_ACK.\n" }
        $ws->{owner}{heartbeat_count} = 0;
      } else {
        print "Received unknown message: '$buf'\n";
      }
    }
  );

  return bless $self;
}

# Set the handler when a dispatch message is received.
sub register_dispatch_object {
  my $self = shift;
  my $obj = shift;

  $self->{dispatch} = $obj;
}

# Updates the last-seen sequence number internal state.
sub advance_sequence {
  my $self = shift;
  my $seq = shift;

  if (defined $seq && (!exists $self->{seqnum} || $self->{seqnum} < $seq)) {
    $self->{seqnum} = $seq;
  }
}

# Send a heartbeat opcode
sub send_heartbeat {
  my $self = shift;

  if (DEBUG) { print "Net::Discord::WSClient: Heartbeat (" . $self->{seqnum} . "), unACKed = " . ($self->{heartbeat_count} + 1) . "\n" }

  my $payload = { op => 1, d => $self->{seqnum} };
  $self->{websocket}->write(encode_json($payload));

  $self->{heartbeat_next} = time() + $self->{heartbeat_interval};
  $self->{heartbeat_count} ++;
}

# Send an identify message
sub send_identify {
  my $self = shift;

  if (DEBUG) { print "Net::Discord::WSClient: Identify\n" }

  my $payload = {
    op => 2,
    d => {
      token => $self->{token},
      properties => {
        '$os' => 'unknown', '$browser' => 'Discord.pm', '$device' => 'Discord.pm'
      }
    }
  };
  $self->{websocket}->write(encode_json($payload));
}

sub connect {
  my $self = shift;

  # parse that URL into a TCP connection pattern
  my ($proto, $host, $port, $path);
  if ($self->{url} =~ m/^(?:(?<proto>ws|wss):\/\/)?(?<host>[^\/:]+)(?::(?<port>\d+))?(?<path>\/.*)?$/)
  {
    $host = $+{host};
    $path = $+{path};

    if (defined $+{proto} && defined $+{port}) {
      $proto = $+{proto};
      $port = $+{port};
    } elsif (defined $+{port}) {
      $port = $+{port};
      if ($port == 443) { $proto = 'wss' } else { $proto = 'ws' }
    } elsif (defined $+{proto}) {
      $proto = $+{proto};
      if ($proto eq 'wss') { $port = 443 } else { $port = 80 }
    } else {
      $proto = 'ws';
      $port = 80;
    }
  } else {
    die "Failed to parse Host/Port from URL.";
  }

  # create a connecting socket
  #  SSL_startHandshake is dependent on the protocol: this lets us use one socket
  #  to work with either SSL or non-SSL sockets.
  if (DEBUG) { print "Net::Discord::WSClient: Attempting to open SSL socket to $proto://$host:$port...\n" }

  $self->{tcp_socket} = IO::Socket::SSL->new(
    PeerAddr => $host,
    PeerPort => $proto . '(' . $port . ')',
    Proto => 'tcp',
    SSL_startHandshake => ($proto eq 'wss' ? 1 : 0),
    Blocking => 1
  ) or die "Failed to connect to TCP socket: $!";

  #####################

  # Now that we've set all that up, call connect on $self->{websocket}.
  #  This causes the Protocol object to create a handshake and write it
  #  (using the on_write method we specified: which includes sysread $tcp_socket)
  if (DEBUG) { print "Net::Discord::WSClient: Calling connect on WebSocket client...\n" }
  $self->{websocket}->connect;

  # read until handshake is complete.
  while (! $self->{websocket}->is_ready)
  {
    my $recv_data;

    my $bytes_read = sysread $self->{tcp_socket}, $recv_data, 16384;

    if (!defined $bytes_read) { die "sysread on tcp_socket failed: $!" }
    elsif ($bytes_read == 0) { die "Connection terminated." }

    $self->{websocket}->read($recv_data);
  }

  # guess we're all connected and handshaked now.
  if (DEBUG) { print "Net::Discord::WSClient: Connection successful.\n" }

  # Now, we go into a loop, calling sysread and passing results to client->read.
  #  The client Protocol object knows what to do with the data, and will
  #  call our hooks (on_connect, on_read, on_read, on_read...) accordingly.
  while ($self->{tcp_socket}->connected) {
    # Calculate seconds and microseconds for heartbeat_interval.
    if (defined $self->{heartbeat_interval}) {
      my $timeout = $self->{heartbeat_next} - time();
      if ($timeout < 0) { $timeout = 0; }
if (DEBUG) { print "Next heartbeat in $timeout sec...\n"; }
      my $seconds  = int($timeout);
      my $useconds = int( 1_000_000 * ( $timeout - $seconds ) );
      my $sys_timeout  = pack( 'l!l!', $seconds, $useconds );

     # Set TCP socket timeout value
      $self->{tcp_socket}->setsockopt( SOL_SOCKET, SO_RCVTIMEO, $sys_timeout ) or carp "Couldn't setsockopt: $!";
    }

    # await response
    my $recv_data;
    my $bytes_read = sysread $self->{tcp_socket}, $recv_data, 16384;

    if (!defined $bytes_read) {
      if ($!{EAGAIN}) {
        $self->send_heartbeat();
        if ($self->{heartbeat_count} > 5) {
          carp "Net::Discord::WSClient: 5 heartbeats un-ACKed, disconnecting";
          $self->{websocket}->disconnect();
        }
      } else {
        warn "sysread on tcp_socket failed: $!";
      }
    } elsif ($bytes_read == 0) { die "Connection terminated: $!" }
    else {
      # unpack response: this triggers any handler if a complete packet is read.
      $self->{websocket}->read($recv_data);
    }
  }
}

1;
