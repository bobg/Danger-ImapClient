# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

package Danger::Server::Writer;

use base qw(Danger::Server::Writable);

sub configure {
  my($self, $server, $fh) = @_;

  $self->SUPER::configure($fh);
  $self->{server} = $server;
  $server->add_writer($self);
}

sub server { shift->_field(server => @_) }

sub close {
  my($self, $immediate) = @_;

  $self->SUPER::close($immediate);

  if ($immediate) {
    my $server = $self->server();
    $server->remove_writer($self);
  }
}

1;
