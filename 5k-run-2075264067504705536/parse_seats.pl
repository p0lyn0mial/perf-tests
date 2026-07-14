#!/usr/bin/perl
use strict;
use warnings;

# Parse KAS HTTP traces for system-nodes flow schema.
# Compute per-resource seat occupancy in 1-minute time buckets.
#
# For each successful request:
#   seat_seconds = iseats * execution_time
#   concurrent_seats ≈ sum(seat_seconds) / bucket_duration
#
# Also tracks 429 counts per resource per bucket.

my %buckets;      # {minute}{resource} = { seat_sec, count, exec_sum, apf_sum, lat_sum, slow, count_429 }
my %global_res;   # all resources seen

sub to_secs {
    my $s = shift;
    return $1+0    if $s =~ /^([\d.]+)s$/;
    return $1/1000 if $s =~ /^([\d.]+)ms$/;
    return $1/1e6  if $s =~ /^([\d.e+-]+)\x{b5}s$/ || $s =~ /^([\d.e+-]+)µs$/;
    return $1*60+$2 if $s =~ /^(\d+)m([\d.]+)s$/;
    return $1*3600+$2*60+$3 if $s =~ /^(\d+)h(\d+)m([\d.]+)s$/;
    return 0;
}

while (<>) {
    next unless /apf_fs="system-nodes"/;
    next unless /^I\d+\s+([\d:]+)\.\d+/;
    my $ts = $1;

    # Extract minute bucket (HH:MM)
    my $minute = substr($ts, 0, 5);

    # Extract verb
    my $verb = ($_ =~ /verb="(\w+)"/) ? $1 : "?";

    # Extract resource from URI
    my $res = "unknown";
    if (/URI="([^"]+)"/) {
        my $uri = $1;
        if ($uri =~ m{/api/v1/(?:namespaces/[^/]+/)?([a-z]+)}) {
            $res = $1;
        } elsif ($uri =~ m{/apis/[^/]+/[^/]+/(?:namespaces/[^/]+/)?([a-z]+)}) {
            $res = $1;
        }
        # Detect subresource (token, status, binding)
        if ($uri =~ m{/(?:token|status|binding|scale|proxy)(?:\?|$)}) {
            if ($uri =~ m{/([a-z]+)/[^/]+/(token|status|binding)}) {
                $res = "$1/$2";
            }
        }
    }

    my $key = "$verb $res";

    # Extract response code
    my $resp = ($_ =~ /resp=(\d+)/) ? $1 : "0";

    # Extract iseats
    my $iseats = ($_ =~ /apf_iseats=(\d+)/) ? $1 : 1;

    $buckets{$minute}{$key} //= { seat_sec=>0, count=>0, exec_sum=>0, apf_sum=>0, lat_sum=>0, slow=>0, count_429=>0 };
    my $b = $buckets{$minute}{$key};
    $global_res{$key} = 1;

    if ($resp eq "429") {
        $b->{count_429}++;
        next;
    }

    # Extract execution time
    my $exec = 0;
    if (/apf_execution_time="([^"]+)"/) {
        $exec = to_secs($1);
    }

    # Extract APF wait
    my $apf = 0;
    if (/fl_priorityandfairness="([^"]+)"/) {
        $apf = to_secs($1);
    }

    # Extract total latency
    my $lat = 0;
    if (/latency="([^"]+)"/) {
        $lat = to_secs($1);
    }

    $b->{seat_sec} += $iseats * $exec;
    $b->{count}++;
    $b->{exec_sum} += $exec;
    $b->{apf_sum} += $apf;
    $b->{lat_sum} += $lat;
    $b->{slow}++ if $lat > 1.0;
}

# Output: per-minute seat occupancy by resource
print "=== PER-RESOURCE SEAT OCCUPANCY (avg concurrent seats per minute) ===\n";
print "Concurrent seats = sum(iseats * exec_time) / 60s\n\n";

# Header
printf "%-6s", "Time";
# Sort resources by total seat-seconds
my %total_seats;
for my $min (keys %buckets) {
    for my $r (keys %{$buckets{$min}}) {
        $total_seats{$r} += $buckets{$min}{$r}{seat_sec};
    }
}
my @top_res = (sort { $total_seats{$b} <=> $total_seats{$a} } keys %total_seats)[0..14];
for my $r (@top_res) {
    printf " %20s", substr($r, 0, 20);
}
printf " %10s", "TOTAL";
print "\n";

for my $min (sort keys %buckets) {
    printf "%-6s", $min;
    my $total = 0;
    for my $r (@top_res) {
        my $b = $buckets{$min}{$r};
        my $seats = $b ? $b->{seat_sec} / 60.0 : 0;
        $total += $seats;
        printf " %20.1f", $seats;
    }
    # Add remaining resources
    for my $r (keys %{$buckets{$min}}) {
        next if grep { $_ eq $r } @top_res;
        my $b = $buckets{$min}{$r};
        $total += $b->{seat_sec} / 60.0;
    }
    printf " %10.1f", $total;
    print "\n";
}

print "\n=== PER-RESOURCE SUMMARY (full test) ===\n";
printf "%-25s %10s %10s %12s %10s %10s %10s %10s\n",
    "Resource", "Count", "429s", "SeatSec", "AvgSeats", "AvgExec", "AvgAPFwait", "Slow>1s";
for my $r (sort { $total_seats{$b} <=> $total_seats{$a} } keys %total_seats) {
    my ($cnt, $c429, $ss, $esum, $asum, $lsum, $slow) = (0,0,0,0,0,0,0);
    for my $min (keys %buckets) {
        my $b = $buckets{$min}{$r};
        next unless $b;
        $cnt += $b->{count};
        $c429 += $b->{count_429};
        $ss += $b->{seat_sec};
        $esum += $b->{exec_sum};
        $asum += $b->{apf_sum};
        $lsum += $b->{lat_sum};
        $slow += $b->{slow};
    }
    next if $cnt + $c429 < 100;
    my $duration_min = scalar(keys %buckets);
    printf "%-25s %10d %10d %12.0f %10.1f %10.4fs %10.3fs %10d\n",
        $r, $cnt, $c429, $ss, $ss/($duration_min*60),
        $cnt>0 ? $esum/$cnt : 0, $cnt>0 ? $asum/$cnt : 0, $slow;
}
