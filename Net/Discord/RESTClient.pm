#!/usr/bin/env perl
package Net::Discord::RESTClient;

use strict;
use warnings;

# Module for interacting with the REST service
use LWP::UserAgent;
# JSON decode
use JSON::PP qw(encode_json decode_json);
# better error messages
use Carp qw(carp);

# debug
use constant DEBUG => 0;

# Raw GET: pass URL, return JSON, warn on error.
sub req {
  my $self = shift;
  my $endpoint = shift;
  my $type = shift || 'GET';
  my $data = shift;

  # Make request, should return some json
  my $url = $self->{base_url} . $endpoint;

  if (DEBUG) { print "Net::Discord::RESTClient: calling $type($url)\n" }

  my $req = HTTP::Request->new( $type, $url );

  # Set the Bot Token
  $req->header('Authorization' => 'Bot ' . $self->{token});

  if ($type ne 'GET') {
    $req->header( 'Content-Type' => 'application/json' );
    $req->content( encode_json($data) );
  }

  my $response = $self->{ua}->request( $req );
  if ( ! $response->is_success ) {
    carp "Net::Discord::RESTClient: Warning - $type($endpoint) returned: " . $response->status_line . " (" . $response->decoded_content . ")";
    return undef;
  }

  if (DEBUG) { print "Net::Discord::RESTClient: received " . $response->decoded_content . "\n" }

  return decode_json( $response->decoded_content );
}

##################################################

sub new {
  my $class = shift;

  my (%params) = @_;

  # check parameters
  die 'token is required' unless $params{token};

  # create class with some params
  my $self = bless { token => $params{token} };

  # Create an LWP UserAgent for REST requests
  $self->{ua} = LWP::UserAgent->new;
  $self->{ua}->agent('Discord.pm (https://github.com/greg-kennedy/Discord.pm, 0.1)');
  $self->{ua}->timeout(10);
  $self->{ua}->env_proxy;
  $self->{ua}->cookie_jar( {} );

  $self->{base_url} = 'https://discordapp.com/api/v6';

  return $self;
}

1;
