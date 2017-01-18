#!/usr/bin/env perl

use strict;
use warnings;
use POSIX qw(floor);

my @delay_rules;

sub hmsms2tm($$$$) {
    my ($h, $m, $s, $ms) = @_;
    die "$ms too long for msec\n" if length($ms) > 3;
    $ms *= 10 ** (3 - length($ms)) if length($ms) < 3;
    return [($h * 60 + $m) * 60 + $s, $ms];
};

sub neg_tm($) {
    my ($tm) = @_;
    return [-$tm->[0], -$tm->[1]];
};

sub normalize_tm($) {
    my ($tm) = @_;
    if ($tm->[1] >= 1000) {
	use integer;
	$tm->[0] += $tm->[1] / 1000;
	$tm->[1] %= 1000;
	no integer;
    } elsif ($tm->[1] <= -1000) {
	use integer;
	$tm->[0] -= -$tm->[1] / 1000;
	$tm->[1] = -(-$tm->[1] % 1000);
	no integer;
    };
    if ($tm->[0] > 0 and $tm->[1] < 0) {
	$tm->[0] -= 1;
	$tm->[1] += 1000;
    } elsif ($tm->[0] < 0 and $tm->[1] > 0) {
	$tm->[0] += 1;
	$tm->[1] -= 1000;
    };
};

sub cmp_tm($$) {
    my ($tmA, $tmB) = @_;
    my $c1 = $tmA->[0] <=> $tmB->[0];
    return $c1 ? $c1 : $tmA->[1] <=> $tmB->[1];
};

sub add_tm($$) {
    my ($tmA, $tmB) = @_;
    my $tm = [$tmA->[0] + $tmB->[0], $tmA->[1] + $tmB->[1]];
    normalize_tm $tm;
    return $tm;
};

sub sub_tm($$) {
    my ($tmA, $tmB) = @_;
    return add_tm($tmA, neg_tm($tmB));
};

sub tm2hmsms($) {
    my ($tm) = @_;
    my $t = $tm->[0];
    my ($h, $m, $s, $ms);
    use integer;
    $s = sprintf "%02i", ($t % 60);
    $t /= 60;
    $m = sprintf "%02i", ($t % 60);
    $t /= 60;
    $h = sprintf "%02i", $t;
    no integer;
    $ms = sprintf "%03i", $tm->[1];
    return ($h, $m, $s, $ms);
};

foreach (@ARGV) {
    my ($h0, $m0, $s0, $ms0, $dtm);
    if (/\A\s*(?:(?:(\d+):)?(\d+):)?(\d+)(?:[.,](\d{1,3}))?
	(\+|-)(\d+)(?:[.,](\d{1,3}))?\s*\z/x) {
	my ($sign, $ds, $dms);
	($h0, $m0, $s0, $ms0, $sign, $ds, $dms) =
	    ($1, $2, $3, $4, $5, $6, $7);
	$h0  = 0 unless defined $h0;
	$m0  = 0 unless defined $m0;
	$ms0 = 0 unless defined $ms0;
	$dms = 0 unless defined $dms;
	$dtm = hmsms2tm(0, 0, $ds, $dms);
	$dtm = neg_tm $dtm if $sign eq "-";
    } elsif (/\A\s*(?:(?:(\d+):)?(\d+):)?(\d+)(?:[.,](\d{1,3}))?
	--?>(?:(?:(\d+):)?(\d+):)?(\d+)(?:[.,](\d{1,3}))?\s*\z/x) {
	my ($h1, $m1, $s1, $ms1);
	($h0, $m0, $s0, $ms0, $h1, $m1, $s1, $ms1) =
	    ($1, $2, $3, $4, $5, $6, $7, $8);
	$h0  = 0 unless defined $h0;
	$m0  = 0 unless defined $m0;
	$ms0 = 0 unless defined $ms0;
	$h1  = 0 unless defined $h1;
	$m1  = 0 unless defined $m1;
	$ms1 = 0 unless defined $ms1;
	my $tm0 = hmsms2tm($h0, $m0, $s0, $ms0);
	my $tm1 = hmsms2tm($h1, $m1, $s1, $ms1);
	$dtm = sub_tm($tm1, $tm0);
    } else {
	die "h:m:s.msec{{+|-}s.msec|-->s.msec} expected"
	    ." instead of $_\n";
    };
    push @delay_rules, [hmsms2tm($h0, $m0, $s0, $ms0), $dtm];
};

my $state = "init";

while (<STDIN>) {
    if ($state eq "init" and /\A\s*\d+\s*\z/) {
	print $_;
	$state = "time";
    } elsif ($state eq "time") {
	die "invalid event time: $_"
	    unless /\A\s*(\d\d):(\d\d):(\d\d),(\d{1,3})\s*-->\s*
	    (\d\d):(\d\d):(\d\d),(\d{1,3})(\s*)\z/x;
	my ($h0, $m0, $s0, $ms0, $h1, $m1, $s1, $ms1, $crlf) =
	    ($1, $2, $3, $4, $5, $6, $7, $8, $9);
	my $tm0 = hmsms2tm($h0, $m0, $s0, $ms0);
	my $tm1 = hmsms2tm($h1, $m1, $s1, $ms1);
	my $dtm;
	foreach my $delay (@delay_rules) {
	    $dtm = $delay->[1] if cmp_tm($tm0, $delay->[0]) >= 0;
	};
	if (defined $dtm) {
	    printf "%02i:%02i:%02i,%03i --> %02i:%02i:%02i,%03i%s",
		tm2hmsms(add_tm($tm0, $dtm)),
		tm2hmsms(add_tm($tm1, $dtm)), $crlf;
	} else {
	    print $_;
	};
	$state = "text";
    } elsif ($state eq "text") {
	print $_;
	$state = "init" if /\A[\r\n]*\z/;
    };
};

# vi:set sw=4 noet ts=8 tw=71:
