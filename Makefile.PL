use strict;
use warnings;

use ExtUtils::MakeMaker;

my %PL;
my %PM;
my @EXE;
open(M, 'MANIFEST') or die "Cannot open MANIFEST ($!)\n";
while (<M>) {
  chomp;
  if (/^lib\/(.*\.pm)$/) {
    $PM{$_} = "\$(INST_LIBDIR)/$1";
  } elsif (/^(s?bin\/.*)\.PL$/) {
    $PL{$_} = $1;
    push(@EXE, $1);
  }
}
close(M);

&WriteMakefile(NAME         => 'Danger-Server',
               VERSION      => '0.1',
               EXE_FILES    => \@EXE,
               PL_FILES     => \%PL,
               PM           => \%PM,
               PREREQ_PM    => { },
               clean        => {FILES => join(' ', @EXE)});
