use strict;
use warnings;

package Danger::Logger;

use POSIX qw(strftime);

my %levels = (LOG_ERROR => 1,
              LOG_WARN => 2,
              LOG_NOTICE => 3,
              LOG_INFO => 4,
              LOG_DEBUG => 5,
              LOG_DEBUG2 => 6);

my $_level = $levels{LOG_INFO};

sub logf {
  my $level = shift;

  return unless
      ($levels{$level} && ($levels{$level} <= $_level))

  my $fmt = shift;
  my $str = sprintf($fmt, @_);
  my $prefix = sprintf('[%s p:%d l:%s] ',
                       &POSIX::strftime('%Y%m%d-%H:%M:%S', localtime(time)),
                       $$, $level);
  $str =~ s/^/$prefix/mg;
  print STDERR "$str\n";
}

sub set_log_level {
  my $level = shift;
  $_level = $levels{$level};
}

1;
