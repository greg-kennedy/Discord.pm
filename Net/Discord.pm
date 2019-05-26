#!/usr/bin/env perl
package Net::Discord;

use strict;
use warnings;

# Perl Discord api module
#  Greg Kennedy 2019

use Net::Discord::RESTClient;
use Net::Discord::WSClient;

use List::Util qw( any );

# Module for interacting with the Gateway Websocket servire
# JSON decode
use JSON::PP qw(encode_json decode_json);

# IO::Socket::SSL lets us open encrypted (wss) connections
use IO::Socket::SSL;
use Socket qw( SOL_SOCKET SO_RCVTIMEO );
use Scalar::Util qw(weaken);

# Protocol handler for WebSocket HTTP protocol
use Protocol::WebSocket::Client;

# debug
use Carp;
use constant DEBUG => 1;
use Data::Dumper;

# events we can register / handle
use constant EVENTS => (
  'HELLO',
  'READY',
  'RESUMED',
  'INVALID_SESSION',
  'CHANNEL_CREATE',
  'CHANNEL_UPDATE',
  'CHANNEL_DELETE',
  'CHANNEL_PINS_UPDATE',
  'GUILD_CREATE',
  'GUILD_UPDATE',
  'GUILD_DELETE',
  'GUILD_BAN_ADD',
  'GUILD_BAN_REMOVE',
  'GUILD_EMOJIS_UPDATE',
  'GUILD_INTEGRATIONS_UPDATE',
  'GUILD_MEMBER_ADD',
  'GUILD_MEMBER_REMOVE',
  'GUILD_MEMBER_UPDATE',
  'GUILD_MEMBERS_CHUNK',
  'GUILD_ROLE_CREATE',
  'GUILD_ROLE_UPDATE',
  'GUILD_ROLE_DELETE',
  'MESSAGE_CREATE',
  'MESSAGE_UPDATE',
  'MESSAGE_DELETE',
  'MESSAGE_DELETE_BULK',
  'MESSAGE_REACTION_ADD',
  'MESSAGE_REACTION_REMOVE',
  'MESSAGE_REACTION_REMOVE_ALL',
  'PRESENCE_UPDATE',
  'TYPING_START',
  'USER_UPDATE',
  'VOICE_STATE_UPDATE',
  'VOICE_SERVER_UPDATE',
  'WEBHOOKS_UPDATE',
);

##################################################

sub new {
  my $class = shift;

  my (%params) = @_;

  # check parameters
  croak 'Net::Discord: Error: "token" is required' unless $params{token};

  # create class with some params
  my $self = bless { token => $params{token} };

  # Create an LWP UserAgent for REST requests
  $self->{RESTClient} = Net::Discord::RESTClient->new(token => $self->{token});

  # Use LWP::UserAgent to get the websocket endpoint
  my $gateway_url = $self->{RESTClient}->req('/gateway/bot')->{url};

  if (DEBUG) { print "Net::Discord: Using $gateway_url as WS Gateway URL\n" }

  # Create a WSS Client object for gateway streaming
  $self->{WSClient} = Net::Discord::WSClient->new(url => $gateway_url, token => $self->{token});
  # Set ourselves as the handler for dispatch messages
  $self->{WSClient}->register_dispatch_object($self);

  # empty user callback handler list
  $self->{callback} = {};

  return $self;
}

# Internal dispatch handler.  This is called by WSClient
sub dispatch {
  my $self = shift;
  my $type = shift;
  my $data = shift;

  if (DEBUG) { print "Net::Discord: Dispatch event called ($type) with data: " . Dumper($data) }

  if (exists $self->{callback}{$type})
  {
    $self->{callback}{$type}->($self, $data);
  }
}

sub run {
  my $self = shift;

  # Create a WSS Client object and give it the URL.
  $self->{WSClient}->connect();
}

# Register a user callback for certain events
sub register {
  my $self = shift;
  my $event = shift;
  my $callback = shift;

  if (defined $callback) {
    if (any { $event eq $_ } EVENTS) {
      $self->{callback}{$event} = $callback;
    } else {
      carp "Net::Discord::register() - Event '$event' does not exist!";
    }
  } else {
    if (exists $self->{callback}{$event}) {
      delete $self->{callback}{$event};
    } else {
      carp "Net::Discord::register() - Attempt to de-register callback for '$event', but none registered";
    }
  }
}

1;
