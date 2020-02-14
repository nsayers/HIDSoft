#!/usr/bin/perl
use warnings;

use DBD::mysql;

my %config = do '/usr/local/sbin/HIDSoft/bin/config.pl';

my $filename = '/tmp/IOLinkerRules';

open (my $fh, '>', $filename) or die "Could not open file '$filename' $!"; 

# PERL MYSQL CONNECT()
$connect = DBI->connect("DBI:mysql:database=$config{database};host=$config{host}",$config{user},$config{pw});


print $fh "# IO Linker Rules configuration file\n";
print $fh "#               IO Linker Rules	\n";
print $fh "# ------------------------------------------------ \n";
print $fh "# Supported syntax:\n";
print $fh "# set <option>\n";
print $fh "# ... and ...\n";
print $fh "# <output> = <expression>\n";
print $fh "# where output is:\n";
print $fh "#   O(<interface>,<function_code>)                 - output (set/clear type)\n";
print $fh "#   OM(<interface>,<function_code>)                - momentary output\n";
print $fh "#   E(<msgnum>,<interface>,<class_code>)           - events to eventlogger\n";
print $fh "#   ER(<msgnum>,<interface>,<reader>,<class_code>) - reader events to eventlogger\n";
print $fh "#   G(<group_id>)                                  - activate output group\n";
print $fh "#   L(<logical_id>)                                - set a logical value\n";
print $fh "#   T(<timer_number>,<interval>,<timer_type>)      - define a timer\n";
print $fh "#\n";
print $fh "# and expressions are combinations of:\n";
print $fh "#   I(<interface>,<status_bit>)                    - reflects status bit value\n";
print $fh "#   I(<internal_id>,<interface>,<status_bit>)      - reflects status bit value\n";
print $fh "#   L(<logical_id>)                                - logical bit value\n";
print $fh "#   S(<schedule_number>)                           - true if in schedule\n";
print $fh "#   T(<timer_number>)                              - reflects value of timer\n";
print $fh "#\n";
print $fh "set peer_notification_interval 300\n";
print $fh "set schedule_poll_interval 60\n";

#
#Set some bits for normal operations
#
#
print $fh "# Send event message 901 for Door 1 Forced Door Alarm on IF 0\n";
print $fh "E(901,00,20)=I(00,25)\n";
print $fh "# Send event message 902 for Door 2 Forced Door Alarm on IF 0\n";
print $fh "#E(902,00,20)=I(00,27)\n";
print $fh "# Send event message 903 for Door 1 Door Held Alarm on IF 0\n";
print $fh "#E(903,00,20)=I(00,24)\n";
print $fh "# Send event message 904 for Door 2 Door Held Alarm on IF 0\n";
print $fh "#E(904,00,20)=I(00,26)\n";
print $fh "# Send event message 910 for Tamper Switch Alarm on IF 0\n";
print $fh "#E(910,00,20)=I(00,19)\n";
print $fh "# Send event message 911 for AC Failure Alarm on IF 0\n";
print $fh "#E(911,00,20)=I(00,21)\n";
print $fh "# Send event message 912 for Battery Failure Alarm on IF 0\n";
print $fh "#E(912,00,20)=I(00,23)\n";
print $fh "# Send event message 915 when any tamper input point changes state\n";
print $fh "#    ... add additional entry for each interface on the system\n";
print $fh "#E(915,32,20)=I(32,8) | I(00,18)\n";

if($ARGV[0]) {
my $sth = $connect->prepare("select `mac`,`schid` from HIDReaders WHERE `mac` = '$ARGV[0]'");
$sth->execute();
while (@row = $sth->fetchrow_array()) {
        if($row[1] =~ /,/) {
        @list = split(',',$row[1]);
        foreach $i (@list) {
        print $fh "O(0,1)=S($i)  # Auto Clear Forced on schedule $i \n";
        print $fh "O(0,0)=S($i)  # Open Relay of Schedule $i \n";
        print $fh "O(0,2)=S($i)  # Green light when on Schedule $i \n";
        print $fh "G(1)=S($i)    # Disable Forced Alarm when on Schedule $i \n";
        print $fh "G(2)=S($i)    # Disable Held Alarm Schedule $i \n\n";
                }
	} elsif ($row[1] =~ /^-?(0|([1-9][0-9]*))(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) {
	$i = $row[1];
	print $fh "O(0,0)=S($i)  # Auto Clear Forced on schedule $row[1] \n";
        print $fh "O(0,0)=S($i)  # Open Relay of Schedule $row[1] \n";
        print $fh "O(0,2)=S($i)  # Green light when on Schedule $row[1] \n";
        print $fh "G(1)=S($i)    # Disable Forced Alarm when on Schedule $row[1] \n";
        print $fh "G(2)=S($i)    # Disable Held Alarm Schedule $row[1] \n\n";
	} else {
        print $fh "O(0,0)=S(1)  # Auto Clear Forced on schedule $row[1] \n";
        print $fh "O(0,0)=S(1)  # Open Relay of Schedule $row[1] \n";
        print $fh "O(0,2)=S(1)  # Green light when on Schedule $row[1] \n";
        print $fh "G(1)=S(1)    # Disable Forced Alarm when on Schedule $row[1] \n";
        print $fh "G(2)=S(1)    # Disable Held Alarm Schedule $row[1] \n\n";
	}
}

close $fh;
system("sudo mv /tmp/IOLinkerRules /tmp/IOLinkerRules-".$ARGV[0]." ");
system("sudo chmod 755 /tmp/IOLinkerRules-".$ARGV[0]." ");
} 

$connect->disconnect();
