#!/usr/bin/perl

use DBD::mysql;

my %config = do '/usr/local/sbin/HIDSoft/bin/config.pl';

my $filename = '/tmp/Holidays';

open (my $fh, '>', $filename) or die "Could not open file '$filename' $!"; 

# PERL MYSQL CONNECT()
$connect = DBI->connect("DBI:mysql:database=$config{database};host=$config{host}",$config{user},$config{pw});

print $fh "# Holiday and special event configuration file \n";
print $fh "# defined as the following \n";
print $fh "# schedule id number \n";
print $fh "# x month \n";
print $fh "#   x day \n";
print $fh "#     x year in 4 digits \n";
print $fh "#       # description \n\n";

$sth2 = $connect->prepare("select `mac`,`schid` from HIDReaders WHERE `mac` = '$ARGV[0]'");
$sth2->execute();
while (@row2 = $sth2->fetchrow()) {
                 if($row2[1] =~ /,/) {
                 @list = split(',',$row2[1]);
                        foreach $i (@list) {
				my $sth = $connect->prepare("select schid,date_format(caldate,'%m') as month,date_format(caldate,'%d') as day,date_format(caldate,'%Y') as year,name from HIDCalendar WHERE (deleted IS NULL or deleted > NOW()) AND schid = '$i' ORDER BY year,month,day asc");
				$sth->execute() or die;
					while (@row = $sth->fetchrow_array()) {
			        		print $fh "$row[0]  $row[1]  $row[2]  $row[3]  #  Event label : $row[4]\n";
                			}
			} 
		} else {
		
		my $sth = $connect->prepare("select schid,date_format(caldate,'%m') as month,date_format(caldate,'%d') as day,date_format(caldate,'%Y') as year,name from HIDCalendar WHERE (deleted IS NULL or deleted > NOW()) AND schid = '$row2[1]' ORDER BY year,month,day asc");
                                $sth->execute();
                                        while (@row = $sth->fetchrow_array()) {
                                                print $fh "$row[0]  $row[1]  $row[2]  $row[3]  #  Event label : $row[4]\n";

					}
		}

}
close $fh;
system("sudo mv /tmp/Holidays /tmp/Holidays-".$ARGV[0]." ");
system("sudo chmod 755 /tmp/Holidays-".$ARGV[0]." ");
 

$connect->disconnect();
