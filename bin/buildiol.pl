#!/usr/bin/perl
use warnings;

use DBD::mysql;

my %config = do '/usr/local/sbin/HIDSoft/bin/config.pl';

my $filename = '/tmp/IOLinkerRules';
my $filename2 = '/tmp/OutputGroups';

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
        my $sth = $connect->prepare("select `mac`,`schid` from HIDReaders WHERE `mac` = '$ARGV[0]' LIMIT 1");
        $sth->execute();
        while (@row = $sth->fetchrow_array()) {

                print $fh "#  To add extended time, check docs page 295\n";
                print $fh "O(0,1)=S(".$row[1].")  # Auto Clear Forced on schedule ".$row[1]." \n";
                print $fh "O(0,0)=S(".$row[1].")  # Open Relay of Schedule ".$row[1]." \n";
                print $fh "O(0,2)=S(".$row[1].")  # Green light when on Schedule ".$row[1]." \n";
                print $fh "G(1)=S(".$row[1].")    # Disable Forced Alarm when on Schedule ".$row[1]." \n";
	} 
}

close $fh;
system("sudo mv /tmp/IOLinkerRules /tmp/IOLinkerRules-".$ARGV[0]." ");
system("sudo chown cardreader:cardreader /tmp/IOLinkerRules-".$ARGV[0]." ");


open (my $fh2, '>', $filename2) or die "Could not open file '$filename2' $!";

print $fh2 "# Output Groups configuration file\n";
print $fh2 "# grpid IF funcCode state\n";
print $fh2 "# Output Groups configuration file\n";
print $fh2 "# grpid  IF  funcCode  state\n";
print $fh2 "    1     0      11      0     # Disable forced door alarm 1\n";
print $fh2 "    1     0       0      1     # Open Door 1\n";
print $fh2 "    1     0      27      0     # Disable forced door alarm 2\n";
print $fh2 "    1     0      16      1     # Open Door 2\n";
print $fh2 "    2     0      11      0     # Disable forced door alarm 1\n";
print $fh2 "    3     0      27      0     # Disable forced door alarm 2\n";

close $fh2;
system("sudo mv /tmp/OutputGroups /tmp/OutputGroups-".$ARGV[0]." ");
system("sudo chown cardreader:cardreader /tmp/OutputGroups-".$ARGV[0]." ");

$connect->disconnect();
