#!/usr/bin/perl

# Schedules configuration file
# i=interval definition i S D I H1 M1 S1 H2 M2 S2
# h=holiday interval definition h S D I H1 M1 S1 H2 M2 S2
# S=schedule id
# D=day code:normal (0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thurs, 5=Fri, 6=Sat)
# D=day code:holiday (1=Holiday Group 1, 2=Holiday Group 2, ....)
# I=interval (0 to 5)
# H1 M1 S1 = Start Hour Min Sec (0 0 0 to 23 59 59)
# H2 M2 S2 = Stop Hour Min Sec (0 0 0 to 23 59 59)
#
# i S D I H1 M1 S1 H2 M2 S2
# (7am-12pm & 12:50-6:30pm Mon-Sat)
# (Holiday Group 1,2,4 - No Access on 1, 8am -12pm & 1pm-5pm on 2 & 4)

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
print $fh "#    D=day code:holiday (1=Holiday Group 1, 2=Holiday Group 2, ....\n";
print $fh "# I=interval (0 to 5)\n";
print $fh "# H1 M1 S1 = Start Hour Min Sec (0 0 0 to 23 59 59)\n";
print $fh "# H2 M2 S2 = Stop Hour Min Sec (0 0 0 to 23 59 59)\n";
print $fh "# i S D I H1 M1 S1 H2 M2 S2\n";

my $sth = $connect->prepare("select HIDSchedule.id,HIDSchedule.name,HOUR(HIDSchedule.monstime) as sch_monstime_hour,MINUTE(HIDSchedule.monstime) as sch_monstime_minute,SECOND(HIDSchedule.monstime) as sch_monstime_sec,HOUR(HIDSchedule.monetime) as sch_monetime_hour,MINUTE(HIDSchedule.monetime) as sch_monetime_minute,SECOND(HIDSchedule.monetime) as sch_monetime_sec,HOUR(HIDSchedule.tuestime) as sch_tuestime_hour,MINUTE(HIDSchedule.tuestime) as sch_tuestime_minute,SECOND(HIDSchedule.tuestime) as sch_tuestime_sec,HOUR(HIDSchedule.tueetime) as sch_tueetime_hour,MINUTE(HIDSchedule.tueetime) as sch_tueetime_minute,SECOND(HIDSchedule.tueetime) as sch_tueetime_sec,HOUR(HIDSchedule.wedstime) as sch_wedstime_hour,MINUTE(HIDSchedule.wedstime) as sch_wedstime_minute,SECOND(HIDSchedule.wedstime) as sch_wedstime_sec,HOUR(HIDSchedule.wedetime) as sch_wedetime_hour,MINUTE(HIDSchedule.wedetime) as sch_wedetime_minute,SECOND(HIDSchedule.wedetime) as sch_wedetime_sec,HOUR(HIDSchedule.thustime) as sch_thustime_hour,MINUTE(HIDSchedule.thustime) as sch_thustime_minute,SECOND(HIDSchedule.thustime) as sch_thustime_sec,HOUR(HIDSchedule.thuetime) as sch_thuetime_hour,MINUTE(HIDSchedule.thuetime) as sch_thuetime_minute,SECOND(HIDSchedule.thuetime) as sch_thuetime_sec,HOUR(HIDSchedule.fristime) as sch_fristime_hour,MINUTE(HIDSchedule.fristime) as sch_fristime_minute,SECOND(HIDSchedule.fristime) as sch_fristime_sec,HOUR(HIDSchedule.frietime) as sch_frietime_hour,MINUTE(HIDSchedule.frietime) as sch_frietime_minute,SECOND(HIDSchedule.frietime) as sch_frietime_sec,HOUR(HIDSchedule.satstime) as sch_satstime_hour,MINUTE(HIDSchedule.satstime) as sch_satstime_minute,SECOND(HIDSchedule.satstime) as sch_satstime_sec,HOUR(HIDSchedule.satetime) as sch_satetime_hour,MINUTE(HIDSchedule.satetime) as sch_satetime_minute,SECOND(HIDSchedule.satetime) as sch_satetime_sec,HOUR(HIDSchedule.sunstime) as sch_sunstime_hour,MINUTE(HIDSchedule.sunstime) as sch_sunstime_minute,SECOND(HIDSchedule.sunstime) as sch_sunstime_sec,HOUR(HIDSchedule.sunetime) as sch_sunetime_hour,MINUTE(HIDSchedule.sunetime) as sch_sunetime_minute,SECOND(HIDSchedule.sunetime) as sch_sunetime_sec from HIDSchedule WHERE HIDSchedule.deleted IS NULL or HIDSchedule.deleted > NOW() ORDER BY HIDSchedule.id");
$sth->execute();

while (@row1 = $sth->fetchrow_array()) {
        print $fh "# Sched $row1[0]\n";
        print $fh "i $row1[0] 0 0 $row1[2] $row1[3] $row1[4] $row1[5] $row1[6] $row1[7]  # Schedule unlock name : $row1[1] \n"; 
        print $fh "i $row1[0] 1 0 $row1[8] $row1[9] $row1[10] $row1[11] $row1[12] $row1[13]  # Schedule unlock name : $row1[1] \n";  
        print $fh "i $row1[0] 2 0 $row1[14] $row1[15] $row1[16] $row1[17] $row1[18] $row1[19]  # Schedule unlock name : $row1[1] \n"; 
        print $fh "i $row1[0] 3 0 $row1[20] $row1[21] $row1[22] $row1[23] $row1[24] $row1[25]  # Schedule unlock name : $row1[1] \n"; 
        print $fh "i $row1[0] 4 0 $row1[26] $row1[27] $row1[28] $row1[29] $row1[30] $row1[31]  # Schedule unlock name : $row1[1] \n"; 
        print $fh "i $row1[0] 5 0 $row1[32] $row1[33] $row1[34] $row1[35] $row1[36] $row1[37]  # Schedule unlock name : $row1[1] \n"; 
        print $fh "i $row1[0] 6 0 $row1[38] $row1[39] $row1[40] $row1[41] $row1[42] $row1[43]  # Schedule unlock name : $row1[1] \n";
        my $hth = $connect->prepare("select HIDHoliday.id,HIDHoliday.name,HOUR(HIDHoliday.stime1) as hol_stime1_hour,MINUTE(HIDHoliday.stime1) as hol_stime1_minute,SECOND(HIDHoliday.stime1) as hol_stime1_sec,HOUR(HIDHoliday.etime1) as hol_etime1_hour,MINUTE(HIDHoliday.etime1) as hol_etime1_minute,SECOND(HIDHoliday.etime1) as hol_etime1_sec,HOUR(HIDHoliday.stime2) as hol_stime2_hour,MINUTE(HIDHoliday.stime2) as hol_stime2_minute,SECOND(HIDHoliday.stime2) as hol_stime2_sec,HOUR(HIDHoliday.etime2) as hol_etime2_hour,MINUTE(HIDHoliday.etime2) as hol_etime2_minute,SECOND(HIDHoliday.etime2) as hol_etime2_sec from HIDHoliday INNER JOIN HIDReaders ON HIDReaders.schid = HIDHoliday.schid WHERE HIDReaders.mac = '".$ARGV[0]."' and HIDHoliday.deleted IS NULL or HIDHoliday.deleted > NOW() ORDER BY HIDHoliday.id");$hth->execute();
        while (@row2 = $hth->fetchrow_array()) {        
                print $fh "h $row1[0] $row2[0] 0 $row2[2] $row2[3] $row2[4] $row2[5] $row2[6] $row2[7]  # Holiday unlock name : $row2[1] \n"; 
                if($row2[8] ne ""){ print $fh "h $row1[0] $row2[0] 1 $row2[8] $row2[9] $row2[10] $row2[11] $row2[12] $row2[13]  # Holiday unlock name : $row2[1] \n"; } 
        }

}
        print $fh "\n";
close $fh;
system("sudo mv /tmp/Schedules /tmp/Schedules-".$ARGV[0]." ");
system("sudo chmod 755 /tmp/Schedules-".$ARGV[0]." ");

$connect->disconnect();
