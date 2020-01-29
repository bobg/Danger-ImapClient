# -*- mode: perl; perl-indent-level: 2; indent-tabs-mode: nil -*-

use strict;
use warnings;

package Danger::Error;

use base qw(Error);

use Carp qw(longmess);
use Danger::Debug;
use Danger::Logger qw(logf);

sub new {
  my $type = shift;
  my $self = new Error(@_);
  $self->{stacktrace} = &longmess($type);
  bless $self, $type;
  &logf(LOG_ERROR => ($self->{user_id} || 0),
	"Throwing exception:\n%s\n", $self->as_string());
  return $self;
}

sub user_id { shift->{user_id} }

sub as_string {
  my $self = shift;

  my %copy = %$self;
  delete $copy{stacktrace};

  return &ddbgsprintf("%s\n%D%s",
                      ref($self), \%copy,
                      $self->{stacktrace});
}

1;
