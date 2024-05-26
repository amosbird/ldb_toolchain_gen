#!/usr/bin/perl

use strict;

my %uniq;

foreach my $arg (@ARGV) {
    recurseLibs($arg);
    delete $uniq{$arg};
}
print join( "\n", keys(%uniq) ) . "\n";

exit 0;

# Written by Igor Ljubuncic (igor.ljubuncic@intel.com)
#            Yuval Nissan (yuval.nissan@intel.com)
# Modified by Amos Bird (amosbird@gmail.com)
sub recurseLibs {
    my $filename = shift;
    return if $uniq{$filename};
    $uniq{$filename} = 1;
    chomp( my @libraries = `/usr/bin/ldd $filename` );
    foreach my $line (@libraries) {
        next if not $line;
        $line =~ s/^\s+//g;
        $line =~ s/\s+$//g;

        if (   ( $line =~ /statically linked/ )
            or ( $line =~ /not a dynamic executable/ ) )
        {
            return;
        }
        elsif (( $line =~ /not found/ )
            or ( $line =~ /linux-vdso.so/ ) )
        {
            next;
        }

        # Split and recurse on libraries (third value is the lib path):
        my @newlibs = split( /\s+/, $line );

        # Skip if no mapped or directly linked
        # Sane output comes with four elements
        if ( scalar(@newlibs) < 4 ) {
            $uniq{ $newlibs[0] } = 1;
            next;
        }

        &recurseLibs( $newlibs[2] );
    }
    return;
}
