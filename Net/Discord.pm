#!/usr/bin/env perl
package Net::Discord;

use v5.014;
use warnings;

# Perl Discord api module
#  Greg Kennedy 2019
use Socket qw( SOL_SOCKET SO_RCVTIMEO );
use Scalar::Util qw(weaken);

# LWP::UserAgent for making REST API requests
use LWP::UserAgent;
# JSON decode
use JSON::PP qw(encode_json decode_json);

# IO::Socket::SSL lets us open encrypted (wss) connections
use IO::Socket::SSL;

# Protocol handler for WebSocket HTTP protocol
use Protocol::WebSocket::Client;

# debug
use constant DEBUG => 1;
use Data::Dumper;

# Queries the REST API for the correct gateway URL, and returns it
sub _get_gateway {
    my $api_endpoint = shift;
    my $token = shift;

    my $ua = LWP::UserAgent->new;
    $ua->agent('Discord.pm (https://github.com/greg-kennedy/Discord.pm, 0.1)');
    $ua->timeout(10);
    $ua->env_proxy;
    $ua->cookie_jar( {} );

    # Set the Bot Token
    $ua->default_header('Authorization' => 'Bot ' . $token);

    my $response = $ua->get($api_endpoint);

    if ( ! $response->is_success ) {
        die $response->status_line . ' (' . $response->decoded_content . ')';
    }

    my $info = decode_json( $response->decoded_content );

    say "Response from _get_gateway:";
    print Dumper($info);

    return $info->{url};
}

# Protocol::WebSocket takes a full URL, but IO::Socket::* uses only a host
#  and port.  This regex section retrieves host/port from URL.
sub _parse_url {
  my $url = shift;

  my ($proto, $host, $port, $path);

  if ($url =~ m/^(?:(?<proto>ws|wss):\/\/)?(?<host>[^\/:]+)(?::(?<port>\d+))?(?<path>\/.*)?$/)
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

  return ($proto, $host, $port, $path);
}

##################################################

sub _payload {
  my $opcode = shift;
  my $data = shift;

  return encode_json( { op => $opcode, d => $data } );
}

sub advance_sequence {
  my $self = shift;
  my $seq = shift;

  if (defined $seq && (!exists $self->{seqnum} || $self->{seqnum} < $seq)) {
    $self->{seqnum} = $seq;
  }
}

sub send_heartbeat {
  my $self = shift;

  my $payload = encode_json( { op => 1, d => $self->{seq} });
  $self->{websocket}->write($payload);
}

sub new {
  my $class = shift;

  my (%params) = @_;

  # check parameters
  die 'token is required' unless $params{token};

  # create class with some params
  my $self = bless { token => $params{token} };

  # First step is to use LWP::UserAgent to get the websocket endpoint
  $self->{url} = _get_gateway("https://discordapp.com/api/gateway/bot", $self->{token});

  # Create a WSS Client object and give it the URL.
  $self->{websocket} = Protocol::WebSocket::Client->new(url => $self->{url} . '/?v=6&encoding=json');
  $self->{websocket}{owner} = $self;
  weaken $self->{websocket}{owner};

  # internal handles for websocket stuff
  # Register important callbacks
  $self->{websocket}->on(
    write => sub {
      my $ws = shift;
      my ($buf) = @_;

      syswrite $ws->{owner}{tcp_socket}, $buf;
    },

    read => sub {
      my $ws = shift;
      my ($buf) = @_;

      # decode the message
      my $response = decode_json($buf);

      # record last-seen sequence number
      # call handler based on opcode
      my $s = $ws->{owner}->advance_sequence($response->{s});
      if ($response->{op} == 0)
      {
        if (exists $ws->{owner}{callback}{$response->{t}})
        {
          $ws->{owner}{callback}{$response->{t}}($ws->{owner}, $response->{d});
        } else {
          warn "No handler for dispatch event $response->{t} (data: " . encode_json($response->{d}) . ")";
        }
      } elsif ($response->{op} == 7) {
        say "RECONNECT REQUEST ($buf)";
        # we don't handle this so just terminate the connect and maybe the caller will re-join.
        $ws->disconnect();
      } elsif ($response->{op} == 10) {
        say "HELLO ($buf)";
        my $timeout = $response->{d}{heartbeat_interval} / 1000.0;
        my $seconds  = int($timeout);
        my $useconds = int( 1_000_000 * ( $timeout - $seconds ) );
        my $sys_timeout  = pack( 'l!l!', $seconds, $useconds );

        $ws->{owner}{tcp_socket}->setsockopt( SOL_SOCKET, SO_RCVTIMEO, $sys_timeout ) or warn "Couldn't setsockopt: $!";

        # send login message
        my $payload = encode_json( { op => 2, d => { token => $ws->{owner}{token}, properties => { '$os' => 'freebsd', '$browser' => 'Discord.pm', '$device' => 'Discord.pm' } } } );
        $ws->write($payload);
      } else {
        say "Received unknown message: '$buf'";
      }
    }
  );

  return bless $self;
}

=pod
sub send {
  my $self = shift;

  my $message = shift;

  $self->{websocket}->write(
}
=cut

sub run {
  my $self = shift;

  # parse that URL into a TCP connection pattern
  my ($proto, $host, $port, $path) = _parse_url($self->{url});
  say "Attempting to open SSL socket to $proto://$host:$port...";

  # create a connecting socket
  #  SSL_startHandshake is dependent on the protocol: this lets us use one socket
  #  to work with either SSL or non-SSL sockets.

  # Placing this in the websocket object is a real hack, but it makes
  #  tcp_socket accessible in the callback.
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
  #  (using the on_write method we specified - which includes sysread $tcp_socket)
  say "Calling connect on WebSocket client...";
  $self->{websocket}->connect;

  # read until handshake is complete.
  while (! $self->{websocket}->{hs}->is_done)
  {
    my $recv_data;

    my $bytes_read = sysread $self->{tcp_socket}, $recv_data, 16384;

    if (!defined $bytes_read) { die "sysread on tcp_socket failed: $!" }
    elsif ($bytes_read == 0) { die "Connection terminated." }

    $self->{websocket}->read($recv_data);
  }

  # guess we're all connected and handshaked now.
  print "<DEBUG>::CONNECTED!!!!!!!!!!!!!!!!\n";

  # Now, we go into a loop, calling sysread and passing results to client->read.
  #  The client Protocol object knows what to do with the data, and will
  #  call our hooks (on_connect, on_read, on_read, on_read...) accordingly.
  while ($self->{tcp_socket}->connected) {
    # await response
    my $recv_data;
    my $bytes_read = sysread $self->{tcp_socket}, $recv_data, 16384;

    if (!defined $bytes_read) { 
      warn "sysread on tcp_socket failed: $!";
      $self->send_heartbeat();
    } elsif ($bytes_read == 0) { die "Connection terminated: $!" }
    else {
      # unpack response - this triggers any handler if a complete packet is read.
      $self->{websocket}->read($recv_data);
    }
  }
}

1;
