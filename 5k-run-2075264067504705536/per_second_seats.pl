#!/usr/bin/perl
use strict;
use warnings;

# Compute per-second CONCURRENT seat demand for system-nodes.
# A request occupies iseats from dispatch_time to dispatch_time + exec_time.
# We approximate: each request's seat interval is [timestamp - apf_wait, timestamp - apf_wait + exec_time]
# i.e., timestamp is when the request finished, exec_time is how long it ran,
# so it started executing at (timestamp - exec_time) approximately.
#
# Actually in KAS traces:
#   timestamp = when the log line is emitted (≈ request end)
#   latency = total request time
#   apf_execution_time = time spent executing after APF dispatch
#   fl_priorityandfairness = time spent in APF queue
#
# So the request was executing during [log_time - exec_time, log_time]
# And each second in that window, it occupied iseats.

sub to_secs {
    my $s = shift;
    return $1+0    if $s =~ /^([\d.]+)s$/;
    return $1/1000 if $s =~ /^([\d.]+)ms$/;
    return $1/1e6  if $s =~ /^([\d.e+-]+)\x{b5}s$/ || $s =~ /^([\d.e+-]+)µs$/;
    return $1*60+$2 if $s =~ /^(\d+)m([\d.]+)s$/;
    return $1*3600+$2*60+$3 if $s =~ /^(\d+)h(\d+)m([\d.]+)s$/;
    return 0;
}

my %second_seats;   # {HH:MM:SS} => total seat-seconds in that 1s window
my %second_reqs;    # {HH:MM:SS} => count of requests executing in that window
my %second_429;     # {HH:MM:SS} => 429 count
my %second_queued;  # {HH:MM:SS} => count of requests arriving (dispatched + 429'd)

while (<>) {
    next unless /apf_fs="system-nodes"/;
    next unless /^I\d+\s+([\d:]+)\.\d+/;
    my $ts_str = $1;  # HH:MM:SS
    
    my ($hh, $mm, $ss) = split /:/, $ts_str;
    my $ts_epoch = $hh * 3600 + $mm * 60 + $ss;
    
    my $resp = ($_ =~ /resp=(\d+)/) ? $1 : "0";
    
    if ($resp eq "429") {
        $second_429{$ts_str}++;
        $second_queued{$ts_str}++;
        next;
    }
    
    my $iseats = ($_ =~ /apf_iseats=(\d+)/) ? $1 : 1;
    
    my $exec = 0;
    if (/apf_execution_time="([^"]+)"/) {
        $exec = to_secs($1);
    }
    next if $exec <= 0;
    
    # Request was executing during [ts_epoch - exec, ts_epoch]
    my $start_epoch = int($ts_epoch - $exec);
    my $end_epoch = int($ts_epoch);
    
    $second_queued{$ts_str}++;  # arrived (roughly)
    
    for my $t ($start_epoch .. $end_epoch) {
        my $h = int($t / 3600);
        my $m = int(($t % 3600) / 60);
        my $s = $t % 60;
        my $key = sprintf("%02d:%02d:%02d", $h, $m, $s);
        
        # For partial seconds at start/end, we count full seat
        $second_seats{$key} += $iseats;
        $second_reqs{$key}++;
    }
}

# Output: per-second seat occupancy, sorted by time, only during busy periods
print "=== PER-SECOND CONCURRENT SEATS (system-nodes) ===\n";
printf "%-10s %8s %8s %8s %8s\n", "Time", "Seats", "Reqs", "429s", "Arrivals";

my $peak_seats = 0;
my $peak_time = "";
my @times = sort keys %second_seats;

for my $t (@times) {
    my $seats = $second_seats{$t} // 0;
    my $reqs = $second_reqs{$t} // 0;
    my $c429 = $second_429{$t} // 0;
    my $arrivals = $second_queued{$t} // 0;
    
    if ($seats > $peak_seats) {
        $peak_seats = $seats;
        $peak_time = $t;
    }
    
    # Only print seconds with significant activity
    next unless $seats > 50 || $c429 > 10;
    printf "%-10s %8d %8d %8d %8d\n", $t, $seats, $reqs, $c429, $arrivals;
}

print "\n=== PEAK STATISTICS ===\n";
printf "Peak concurrent seats: %d at %s\n", $peak_seats, $peak_time;

# Also show distribution of seat demand
my %seat_hist;
for my $t (keys %second_seats) {
    my $seats = $second_seats{$t};
    my $bucket;
    if    ($seats < 50)   { $bucket = "<50" }
    elsif ($seats < 100)  { $bucket = "50-99" }
    elsif ($seats < 150)  { $bucket = "100-149" }
    elsif ($seats < 200)  { $bucket = "200-299" }
    elsif ($seats < 500)  { $bucket = "300-499" }
    elsif ($seats < 1000) { $bucket = "500-999" }
    else                  { $bucket = "1000+" }
    $seat_hist{$bucket}++;
}

print "\nSeat demand distribution (per-second buckets):\n";
for my $b (sort keys %seat_hist) {
    printf "  %-12s: %5d seconds\n", $b, $seat_hist{$b};
}
