Net::Discord
============

A Perl5 module for writing clients to interact with the Discord chat service.

Overview
--------

Net::Discord provides a client interface to the Discord chat service API.  The API is a combination of two parts:

* a REST API, using standard HTTP requests to post updates (messages, commands, etc) to the service, and
* a WebSocket gateway, which establishes a persistent streaming connection to the service to receive updates about client status (receive messages, user join/part, pins, invites)

This module wraps two sub-objects for working with these endpoints: a LWP::UserAgent to make REST requests, and IO::Socket::SSL plus Protocol::WebSocket::Client to connect to the Gateway.  It also handles certain requests from the remote service, e.g. initial handshake and periodic heartbeats.

Usage
-----

Currently, the module works as follows:

* Create a new Net::Discord object via new(), passing the API token plus any optional parameters.
* Register callback functions for various API events.  These functions are called when events occur, and the user receives a reference to the main object plus a hash reference of data describing the event.
* Call run().  This passes control to the object, which makes a connection to the Discord server and manages the connection.  As the client receives events from the server, it will call the relevant user-registered functions.
* run() will return when the client's connection to the server ends (for whatever reason), returning control to your script.

An example follows:

    # Create bot client object
    my $client = Net::Discord->new(token => $token);

    # Provide callbacks for different events
    #  Callbacks receive the client as their first parameter, and
    #  the raw object as their second.
    $client->register('READY', sub { print "Ready: " . Dumper(@_) } );
    $client->register('MESSAGE_CREATE', sub { print "Message received: " . Dumper(@_) } );

    # Run client in background
    $client->run();

Dependencies
------------

* Protocol::WebSocket::Client
* IO::Socket::SSL

Support
-------

This module is in a very early state of development and is highly experimental.  Please submit issues to the Issues tracker.  Pull requests are accepted.
