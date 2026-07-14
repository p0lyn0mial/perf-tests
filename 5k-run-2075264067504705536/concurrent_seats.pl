#!/usr/bin/perl
use strict;
use warnings;

# Compute average concurrent seats per 1-second window.
# For each request completing in second T:
#   seat_seconds_contributed = iseats * exec_time
# Average concurrent seats in that second ≈ sum(seat_seconds) / 1.0
# This is correct because requests finishing in second T were executing
# during (some fraction of) that second.

sub to_secs {
    my $s = shift;
    return $1+0    if $s =~ /^([\d.]+)s$/;
    return $1/1000 if $s =~ /^([\d.]+)ms$/;
    return $1/1e6  if $s =~ /^([\d.e+-]+)\x{b5}s$/ || $s =~ /^([\d.e+-]+)µs$/;
    return $1*60+$2 if $s =~ /^(\d+)m([\d.]+)s$/;
    return $1*3600+$2*60+$3 if $s =~ /^(\d+)h(\d+)m([\d.]+)s$/;
    return 0;
}

my %sec_seat_secs;   # {HH:MM:SS} => total seat-seconds from requests finishing in this second
my %sec_count;       # {HH:MM:SS} => count of dispatched requests finishing in this second
my %sec_429;         # {HH:MM:SS} => 429 count
my %sec_arrivals;    # {HH:MM:SS} => total arrivals (dispatched + 429)
my %sec_iseats_gt1;  # {HH:MM:SS} => count of requests with iseats > 1

while (<>) {
    next unless /apf_fs="system-nodes"/;
    next unless /^I\d+\s+([\d:]+)\.\d+/;
    my $ts_str = $1;

    my $resp = ($_ =~ /resp=(\d+)/) ? $1 : "0";
    
    if ($resp eq "429") {
        $sec_429{$ts_str}++;
        $sec_arrivals{$ts_str}++;
        next;
    }
    
    my $iseats = ($_ =~ /apf_iseats=(\d+)/) ? $1 : 1;
    
    my $exec = 0;
    if (/apf_execution_time="([^"]+)"/) {
        $exec = to_secs($1);
    }
    next if $exec <= 0;
    
    $sec_seat_secs{$ts_str} += $iseats * $exec;
    $sec_count{$ts_str}++;
    $sec_arrivals{$ts_str}++;
    $sec_iseats_gt1{$ts_str}++ if $iseats > 1;
}

print "=== AVERAGE CONCURRENT SEATS PER SECOND (system-nodes) ===\n";
print "AvgSeats = sum(iseats * exec_time) for requests completing in that second\n\n";
printf "%-10s %10s %8s %8s %8s %8s\n", "Time", "AvgSeats", "Reqs", "429s", "Arrive", "iseats>1";

my $peak_seats = 0;
my $peak_time = "";
my @over_100 = 0;
my @over_200 = 0;
my @over_500 = 0;

for my $t (sort keys %sec_seat_secs) {
    my $seats = $sec_seat_secs{$t};
    my $reqs = $sec_count{$t} // 0;
    my $c429 = $sec_429{$t} // 0;
    my $arrivals = $sec_arrivals{$t} // 0;
    my $big = $sec_iseats_gt1{$t} // 0;
    
    if ($seats > $peak_seats) {
        $peak_seats = $seats;
        $peak_time = $t;
    }
    
    push @over_100, $t if $seats > 100;
    push @over_200, $t if $seats > 200;
    push @over_500, $t if $seats > 500;
    
    # Print seconds with notable activity
    next unless $seats > 80 || $c429 > 100;
    printf "%-10s %10.1f %8d %8d %8d %8d\n", $t, $seats, $reqs, $c429, $arrivals, $big;
}

print "\n=== SUMMARY ===\n";
printf "Peak concurrent seats: %.1f at %s\n", $peak_seats, $peak_time;
printf "Seconds with seats > 100: %d\n", scalar @over_100;
printf "Seconds with seats > 200: %d\n", scalar @over_200;
printf "Seconds with seats > 500: %d\n", scalar @over_500;

# Distribution
my %hist;
for my $t (keys %sec_seat_secs) {
    my $s = $sec_seat_secs{$t};
    my $b;
    if    ($s < 10)  { $b = "0-9" }
    elsif ($s < 50)  { $b = "10-49" }
    elsif ($s < 100) { $b = "50-99" }
    elsif ($s < 150) { $b = "100-149" }
    elsif ($s < 200) { $b = "150-199" }
    elsif ($s < 300) { $b = "200-299" }
    elsif ($s < 500) { $b = "300-499" }
    else             { $b = "500+" }
    $hist{$b}++;
}
print "\nSeat demand distribution:\n";
for my $b (sort { ($a =~ /(\d+)/)[0] <=> ($b =~ /(\d+)/)[0] } keys %hist) {
    printf "  %-12s: %5d seconds\n", $b, $hist{$b};
}
