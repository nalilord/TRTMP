#!/usr/bin/env perl

use strict;
use warnings;

my $check_only = 0;
if (@ARGV and $ARGV[0] eq '--check') {
  $check_only = 1;
  shift @ARGV;
}

if (not @ARGV) {
  die "Usage: $0 [--check] <pascal-file>...\n";
}

my %uppercase_operator = map { $_ => 1 } qw(
  and or not xor shl shr div mod in is as
);

sub format_pascal {
  my ($source) = @_;
  my $result = '';
  my $length = length($source);
  my $index = 0;
  my $state = 'code';

  while ($index < $length) {
    my $char = substr($source, $index, 1);
    my $pair = $index + 1 < $length ? substr($source, $index, 2) : '';

    if ($state eq 'string') {
      $result .= $char;
      $index++;
      if ($char eq "'") {
        if ($index < $length and substr($source, $index, 1) eq "'") {
          $result .= "'";
          $index++;
        } else {
          $state = 'code';
        }
      }
      next;
    }

    if ($state eq 'line_comment') {
      $result .= $char;
      $index++;
      $state = 'code' if $char eq "\n";
      next;
    }

    if ($state eq 'brace_comment') {
      $result .= $char;
      $index++;
      $state = 'code' if $char eq '}';
      next;
    }

    if ($state eq 'paren_comment') {
      if ($pair eq '*)') {
        $result .= $pair;
        $index += 2;
        $state = 'code';
      } else {
        $result .= $char;
        $index++;
      }
      next;
    }

    if ($char eq "'") {
      $result .= $char;
      $index++;
      $state = 'string';
      next;
    }

    if ($pair eq '//') {
      $result .= $pair;
      $index += 2;
      $state = 'line_comment';
      next;
    }

    if ($pair eq '(*') {
      $result .= $pair;
      $index += 2;
      $state = 'paren_comment';
      next;
    }

    if ($char eq '{') {
      $result .= $char;
      $index++;
      $state = 'brace_comment';
      next;
    }

    if ($pair eq ':=') {
      $result =~ s/[ \t]+\z//;
      $result .= ':=';
      $index += 2;
      while ($index < $length and substr($source, $index, 1) =~ /[ \t]/) {
        $index++;
      }
      next;
    }

    if ($char =~ /[A-Za-z_]/) {
      my $start = $index;
      $index++;
      while ($index < $length and substr($source, $index, 1) =~ /[A-Za-z0-9_]/) {
        $index++;
      }
      my $token = substr($source, $start, $index - $start);
      my $lower = lc($token);
      $result .= $uppercase_operator{$lower} ? uc($token) : $token;
      next;
    }

    $result .= $char;
    $index++;
  }

  return $result;
}

my $failed = 0;
for my $file (@ARGV) {
  open my $input, '<:raw', $file or die "Cannot read $file: $!\n";
  local $/;
  my $source = <$input>;
  close $input;

  my $formatted = format_pascal($source);
  next if $formatted eq $source;

  if ($check_only) {
    print "$file needs formatting\n";
    $failed = 1;
    next;
  }

  open my $output, '>:raw', $file or die "Cannot write $file: $!\n";
  print {$output} $formatted;
  close $output;
  print "Formatted $file\n";
}

exit($failed);
