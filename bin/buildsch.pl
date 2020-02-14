#!/usr/bin/perl
use warnings;

use DBD::mysql;

my %config = do '/usr/local/sbin/HIDSoft/bin/config.pl';

my $filename = '/tmp/Schedules';

open (my $fh, '>', $filename) or die "Could not open file '$filename' $!"; 

# PERL MYSQL CONNECT()
$connect = DBI->connect("DBI:mysql:database=$config{database};host=$config{host}",$config{user},$config{pw});

print $fh "# Setup the header of the file, cause we do want to be consistent\n";
print $fh "# Schedules configuration file\n";
print $fh "# i=interval definition   i S D I H1 M1 S1 H2 M2 S2\n";
print $fh "# h=holiday definition\n";
print $fh "# S=schedule id\n";
print $fh "# D=day code (0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thurs, 5=Fri, 6=Sat)\n";
print $fh "#    or for holiday D=holiday group\n";
print $fh "# I=interval (0 to 5)\n";
print $fh "# H1 M1 S1 = Start Hour Min Sec (0 0 0 to 23 59 59)\n";
print $fh "# H2 M2 S2 = Stop Hour Min Sec (0 0 0 to 23 59 59)\n\n\n";

my $sth = $connect->prepare("select id,name,dow,time_format(stime,'%H') as shour,time_format(stime,'%i') as sminute,time_format(stime,'%s') as ssecond,time_format(etime,'%H') as ehour,time_format(etime,'%i') as eminute,time_format(etime,'%s') as esecond,hdow from HIDSchedule WHERE deleted IS NULL or deleted > NOW() ORDER BY id,stime");
$sth->execute();

while (@row = $sth->fetchrow_array()) {
        print $fh "# Sched $row[0]\n";
        if ($row[2] =~ /0/) { print $fh "i $row[0] 0 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[2] =~ /1/) { print $fh "i $row[0] 1 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n";  }

        if($row[2] =~ /2/) { print $fh "i $row[0] 2 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[2] =~ /3/) { print $fh "i $row[0] 3 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[2] =~ /4/) { print $fh "i $row[0] 4 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[2] =~ /5/) { print $fh "i $row[0] 5 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[2] =~ /6/) { print $fh "i $row[0] 6 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[9] =~ /0/) { print $fh "h $row[0] 0 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[9] =~ /1/) { print $fh "h $row[0] 1 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n";  }

        if($row[9] =~ /2/) { print $fh "h $row[0] 2 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[9] =~ /3/) { print $fh "h $row[0] 3 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[9] =~ /4/) { print $fh "h $row[0] 4 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[9] =~ /5/) { print $fh "h $row[0] 5 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        if($row[9] =~ /6/) { print $fh "h $row[0] 6 0 $row[3] $row[4] $row[5] $row[6] $row[7] $row[8]  # $row[1] \n"; }

        print $fh "\n";
}
close $fh;
system("sudo mv /tmp/Schedules /tmp/Schedules-".$ARGV[0]." ");
system("sudo chmod 755 /tmp/Schedules-".$ARGV[0]." ");

$connect->disconnect();
