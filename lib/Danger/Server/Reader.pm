# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

package Danger::Server::Reader;

use base qw(Danger::Server::Readable);

sub configure {
  my($self, $server, $fh, $consume_fn, $eof_fn) = @_;

  $self->SUPER::configure($fh, $consume_fn, $eof_fn);
  $self->{server} = $server;
                          
  $server->add_reader($self);
}

sub server { shift->_field(server => @_) }

sub close {
  my $self = shift;

  $self->SUPER::close();

  my $server = $self->server();
  $server->remove_reader($self);
}

1;
