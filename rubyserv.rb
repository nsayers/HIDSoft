#       rubyserv.rb
#       
#       https://github.com/nsayers/HIDSoft
#       

require 'socket'
require 'io/wait'
require 'rubygems'
require 'mysql'
require 'syslog'
require 'thread'


# The "sql" file is a local one, containing
# our method for querying the database.
#require 'sql'

=begin
	# Define variables used by our children. "$stack" is a stack of strings
	# to be written to the socket; "$readermac" is the current connected 
	# reader's MAC address.
=end
$stack = Array.new
$readermac = nil



# Standard server class. This is what listens on port 4070, forking
# a child whenever a client connection is made.
class StdClass
	def initialize
	log("Startup..")
	debugFlag = 0
	
#	Change the process name for the parent.
	$0="HIDSoft: Parent\0"
		
		if ARGV[0] == "debug"
			debugFlag = 1
			log("Debug mode enabled, logging will be verbose.")
		end

		server = TCPServer.new("0.0.0.0", '4070')
		
#		Sit and listen for connections. When you get one, fork a child
#		to deal with communications to the connected client.
		while socket = server.accept
				t = fork() {
					childproc(socket, debugFlag)
				}
				Process.detach(t)
		end
	end
end



# The main process for the children
def childproc(newsocket, debugFlag)
	i = 0
	
=begin
	# cli_addr is now an array containing domain,
	# port, name, and IP address of peer.
=end
	cli_addr = newsocket.peeraddr
	client_ip = cli_addr[3]
	log("New connection from " + client_ip)

# 	Change the process name for this child.
	$0="HIDSoft: Child\0"

	log("Child started in debug mode.") if debugFlag == 1


=begin
	#	The main loop. Listens for incoming data from the reader. If there
	# is none, increment the variable i, then sleep .25 seconds. 
	
	#	Since the reader is configured to send a "HereIAm" heartbeat-
	# like message every 30 seconds, we can assume a lost connection if
	# we haven't heard from the reader in that time span.
=end	
	while i < 130 do
	
	
=begin
		# If the socket is ready, read from it, store it in the
		# variable "message", then split the string into fields
		# using a semicolon as the delimiter.
=end
		if newsocket.ready?
				i = 0
				flag = 1
				message = newsocket.recv(9000)
				fields = message.split(";")

=begin			
			# "flag" is set to 0 when the entire message is parsed.
			# We do this because it's possible to have more than one
			# message from the controller in one long string.
=end
			while flag == 1 do

=begin		  
				# The very first message we should get from the reader.
				#
				# Includes the MAC address of the reader, which we store
				# as a global variable.
=end
				if fields[0] == "1042"		
					$readermac = fields[2]
					$stack << "0070;0010;"
					len = fields[1].to_i
					message = message[len..9000]
					fields = message.split(";")
					if fields[0] == nil; flag = 0; end
					
				# The heartbeat-like "HereIAm" message.
				elsif fields[0] == "1080"
					if debugFlag == 1; log(client_ip+" is alive!"); end
					$stack << "0080;0010;"
					len = fields[1].to_i
					message = message[len..9000]
					fields = message.split(";")
					if fields[0] == nil; flag = 0; end
					
				# A reader "looking up" a card for potential access.
				elsif fields[0] == "1073"
					$stack << "0073;0012;0;"
					len = fields[1].to_i
					if debugFlag == 1; log("Card lkup: "+message[0..len]); end
					Thread.new { parseCard(message, newsocket) }
					message = message[len..9000]
					fields = message.split(";")
					
				# A log message from the reader.
				elsif fields[0] == "1065" || fields[0] == "1060" || fields[0] == "1061"
					if debugFlag == 1; log("LogMsg: "+message); end
					$stack << "0067;0010;"
					Thread.new { parseMsg(message) }
					flag = 0
					
				# If there is no more string to parse, set the flag.
				elsif fields[0] == nil || fields[0] == "" || flag == 0
					flag = 0
					
				else
					if debugFlag == 1; log("Received: "+message); end
					flag = 0
				end
	
				# If there is a message waiting on the stack,
				# write it to the socket.
				if $stack[0] != nil
					if $stack[0] == "sleep"
						sleep 0.5
						$stack.shift
						
					else
						if debugFlag == 1; log("Rdr: "+client_ip+"   Wrote: "+$stack[0]); end
						begin; newsocket.write $stack[0]; rescue exit; end
						$stack.shift
						
					end
					
				end
   
			end
		
		else
		  i = i + 1

			if $stack[0] != nil
				if $stack[0] == "sleep"
					sleep 0.5
					$stack.shift
					
				else
					if debugFlag == 1; log("Wrote: "+$stack[0]); end
					begin; newsocket.write $stack[0]; rescue exit; end
					$stack.shift
					
				end
				
			end
			
			if $readermac != nil
			  if i == 10 || i == 20 || i == 30 || i == 40 || i == 50 || i == 60 || i == 70 || i == 80 || i == 90 || i == 100; chkManualOverride(newsocket); end
			  
			end
		
		end
	  #puts i
  	  sleep 0.25
  	  
  	end
  log("Detected lost connection from "+client_ip+". Exiting.")
  newsocket.close
  
end

def sqlq(msg)
# Hostname, username, password, database.
        begin
          my = Mysql.real_connect("localhost", "root", "password", "readers")
          res = my.query(msg)
        rescue Mysql::Error => e
          log(e.errno)
          log(e.error)
        ensure
          my.close if my
        end

  return res
end



# Method that determines whether or not a card being looked up should
# be allowed access to the door.
def parseCard(msg, socket)
	fields = msg.split(";")
	cardNum = fields[2]
	mac = fields[7]
	grantFlag = 0
	action = "deny"
	modFlag = 0

	socket.write "0094;0016;0;9;0;"

	# Prepare the query, send it off to the "sqlq" method.
   	cardq = "SELECT `groupid`, `contact_id`, `id` FROM `HIDCards` WHERE `cardnum` ='"+fields[13]+"'"
   	log("card query: "+cardq)
   	res = sqlq(cardq)

        if res.num_rows > 0
            log("Found card record for "+fields[13]+", checking for expiration.")
            cardrow = res.fetch_row
            cardexpireq = "select `groupid`, `contact_id`,`id` from HIDCards WHERE `cardnum` = '"+fields[13]+"' AND (`expires` IS NULL OR `expires` > NOW())"
            log("Check Expire : "+cardexpireq)
            cardexpireres = sqlq(cardexpireq)

            if cardexpireres.num_rows > 0
            readerq = "SELECT `groups` FROM `HIDReaders` WHERE `mac`='"+fields[10]+"'"
            log("DEBUG: "+readerq)
            readerres = sqlq(readerq)
            	if readerres.num_rows > 0
            	readerrow = readerres.fetch_row
                groups = readerrow[0].split(",")

                	i = 0
                	#   puts groups[i]
                	while groups[i] != nil do
                		if groups[i] == cardrow[0]              # If this card is allowed access to this door..
                			grantFlag = 1                           # Set the grant flag to 1
                			actionq = "INSERT INTO HIDLog (reader, taskcode, message) VALUES ('"+$readermac+"', 'GRANT', '"+fields[13]+"')" # Action.
                			log("Insert query: "+actionq)

                			# Prepare the string to modify the card record
                			str = "0;1;"+fields[2]+";0;1;"+cardrow[2]+";1;2;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;0;1;"
                			len = str.length + 10
                			addMod = "0024;00"+len.to_s+";"+str
                			modFlag = 1
                			log("String returned: "+str)
                		end
                	i = i + 1

                	end
                end
            else
               	log("DENIED USER, expired card "+fields[13])
               	grantFlag = 0
            end


            if grantFlag == 0       # If the user isn't allowed in this door..
            actionq = "INSERT INTO HIDLog (reader, taskcode, message) VALUES ('"+$readermac+"', 'DENY-NOACC', '"+fields[13]+"')"
            end
        else
          log("No card record found.")
          # Unknown card
          actionq = "INSERT INTO HIDLog (reader, taskcode, message) VALUES ('"+$readermac+"', 'DENY-UNKWN', '"+fields[13]+"')"
	  log("Query to HIDLog "+actionq)
        end

    actionres = sqlq(actionq)

    if grantFlag == 1
    	log("Granting access..")
    	socket.write "0094;0016;0;7;2;"
    else
    	log("Denying access..")
    	socket.write "0094;0016;0;8;2;"
    end

    if modFlag == 1
    	$stack << "sleep"
    	$stack << addMod
    	modFlag = 0
    end
end


# Method that parses log messages from the reader, performs actions
# accordingly (insert a message into the database when a card is read, etc.).
def parseMsg(msg)
bundleFlag = 0

newmsg = msg.split("^")
fields = newmsg[0].split(";")
# Insert a message on to the stack:	 $stack << fields[0]

	if fields[0] == "1065"
		bundleFlag = 1
		fields.shift
		fields.shift
	end

	
		while newmsg[0] != nil
			info0 = fields[0]  # Event or alarm?
			info1 = fields[1]  # Message ID (arbitrary number)
			info2 = fields[2]  # Message Type
			info3 = fields[3]  # Class code
			info4 = fields[4]  # Task Code
			info5 = fields[5]  # Event Code
			info6 = fields[6]  # Priority Code
			info7 = fields[7]  # Message Time
			info8 = fields[8]  # MAC of the reader
			info9 = fields[9]  # Extra field 1
			info10 = fields[10] # Extra field 2
			info11 = fields[11] # Extra field 3
			info12 = fields[12] # Extra field 4
			info13 = fields[13] # Extra field 5
=begin
		if debugFlag == 1
			log("Event or alarm? "+info0)
			log("Message ID: "+info1)
			log("Type: "+info2)
			log("Class Code: "+info3)
			log("Task Code: "+info4)
			log("Event Code: "+info5)
			log("Priority Code: "+info6)
			log("Time: "+info7)
			log("MAC: "+info8)
			if info9 != nil; log("X1: "+info9); end
			if info10 != nil; log("X2: "+info10); end
			if info11 != nil; log("X3: "+info11); end
			if info12 != nil; log("X4: "+info12); end
			if info13 != nil; log("X5: "+info13); end
		end
=end
			
			
			datefields = fields[7].split(" ")
			parts = datefields[2].split("/")
			timestamp = parts[2]+"-"+parts[0]+"-"+parts[1]+" "+datefields[0]
			

			if info0 == "1060" 				# If event..
				
				if info4 == "2"				# If Task Code == "2" (access)			
					if info2 == "1"			# If Message Type == "1"				
						if info5 == "20"
							sqlq("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES ('"+$readermac+"', 'GRANT', '"+info11+"', '"+timestamp+"')")
							  if $readermac == '00:06:8E:01:10:C8'
								u1 = UDPSocket.new
							        u2 = UDPSocket.new	
								u1.send '<189> HID: Front Door Opened', 0, "192.168.8.3", 514
								u2.send '<189> HID: Front Door Opened', 0, "209.147.112.123", 514
							  end
#							qres.close
							
						elsif info5 == "23"
							sqlq("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES ('"+$readermac+"', 'DENY-NOACC', '"+info11+"', '"+timestamp+"')")
#							qres.close
							
						elsif info5 == "36"
							sqlq("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES ('"+$readermac+"', 'DENY-EXPIRE', '"+info11+"', '"+timestamp+"')")
#							qres.close
						end
					elsif info2 == "2"			
					
					end

				# I/O Linker Task code (door alarm)        
                                elsif info4 == "4"        
                                
					if info11 == "901"

						# Door has been forced. Log this, clear the alarm.
						if info12 == "1"
							sqlq("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES ('"+$readermac+"', 'ALARM', 'DOOR HAS BEEN FORCED', '"+timestamp+"')")
							sqlq("UPDATE HIDAlarm SET alarm='1' WHERE id='1'")
							$stack << "0094;0017;0;11;0;"

						# Door is now closed after being forced. Re-arm the alarm.
						elsif info12 == "0"
							$stack << "0094;0017;0;11;1;"

						end
									
					# Check to see if there is a held door, programmed on the reader @ /mnt/data/config/IOLinker.conf
					elseif info11 == "903"

                                                # Door has been held. Log this, clear the alarm.
                                                if info12 == "1"
                                                        sqlq("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES ('"+$readermac+"', 'HELD', 'DOOR HAS BEEN HELD', '"+timestamp+"')")
                                                #        sqlq("UPDATE HIDAlarm SET held='1' WHERE id='1'")
                                                        $stack << "0094;0017;0;11;0;"

                                                # Door is now closed after being forced. Re-arm the alarm.
                                                elsif info12 == "0"
                                                        $stack << "0094;0017;0;11;1;"

                                                end
	
					
					end
					
				end
				
			end

		
			newmsg.shift
				begin; fields = newmsg[0].split(";"); rescue; newmsg[0] = nil; end
			
		end

  
end



# Method that checks the database to see if this process needs to do
# anything special, like resending the access database, manually opening a door, etc.
def chkManualOverride(socket)
  cardq = "SELECT `manual_open`, `cmd` FROM `HIDReaders` WHERE `mac` ='"+$readermac+"'"
  res = sqlq(cardq)
  num = res.num_rows
  row = res.fetch_row

  
	if num.to_i == 0		# If this reader does not exist in our database..
		sqlq("INSERT INTO HIDReaders (mac, name, groups, manual_open) VALUES ('"+$readermac+"','"+$readermac+"','0','101')")
		return 1
		
	else
	
		if row[0] == "1"
		  $stack << "0094;0016;0;7;2;"
		
	
  sqlq("INSERT INTO HIDLog (reader, taskcode, message) VALUES ('"+$readermac+"', 'GRANT', 'Manual Admit')")
    if $readermac == '00:06:8E:01:10:C8'
	u1 = UDPSocket.new
        u2 = UDPSocket.new

	u1.send '<189> HID: Front Door Opened', 0, "192.168.8.3", 514
	u2.send '<189> HID: Front Door Opened', 0, "209.147.112.123", 514
    end
#  puts "INSERT INTO HIDLog (reader, taskcode, message) VALUES ('"+$readermac+"', 'GRANT', 'Manual Admit')"
  sqlq("UPDATE HIDReaders SET manual_open ='0' WHERE mac='"+$readermac+"'")
#  puts "UPDATE HIDReaders SET manual_open ='0' WHERE mac='"+$readermac+"'"
		
		elsif row[0] == "100"
			log("Calling new reader setup.")
			stat = newReaderSetup(socket)
			sqlq("UPDATE HIDReaders SET manual_open ='0' WHERE mac='"+$readermac+"'")
		elsif row[0] == "200"
			log("Calling Credentials database Refresh.")
			sqlq("UPDATE HIDReaders SET manual_open ='0' WHERE mac='"+$readermac+"'")
			stat = sendAccessDB(socket)
		elsif row[0] == "300"
			log("Deploying files for Reader '"+$readermac+"'")
			system("/usr/local/sbin/HIDSoft/bin/buildho.pl '"+$readermac+"'")
			system("sleep 3 && /usr/local/sbin/HIDSoft/bin/buildiol.pl '"+$readermac+"'")
			system("sleep 6 && /usr/local/sbin/HIDSoft/bin/buildsch.pl '"+$readermac+"'")
			system("sleep 10 && /usr/local/sbin/HIDSoft/bin/deploy.sh '"+$readermac+"'")
			sqlq("UPDATE HIDReaders SET manual_open ='999' WHERE mac='"+$readermac+"'")
		elsif row[0] == "400"
			log("BuildDB Files for "+$readermac+" ")
			system("/usr/local/sbin/HIDSoft/bin/builddb.sh '"+$readermac+"' && sleep 5")
			sqlq("UPDATE HIDReaders SET manual_open ='200' WHERE mac='"+$readermac+"'")
                elsif row[0] == "500"
                        log("Sending Time to reader"+$readermac+".")
                        sqlq("UPDATE HIDReaders SET manual_open ='0' WHERE mac='"+$readermac+"'")
                        stat = sendTime(socket)
		elsif row[0] == "999"
			log("Reader reboot requested")
			sqlq("UPDATE HIDReaders set manual_open ='0' where mac='"+$readermac+"'")
                        $stack << "0012;0013;99;"

		end
		
		if row[1] != "0"
			# Code block to process commands.
		end
	end
	
end



# Method to refresh permissions databases on the reader.
def sendAccessDB(socket)
	flag = 0
	db = File.open("/tmp/NewAccessDB-"+$readermac, "r")
	data = db.read
	len = data.size + 10
	lenlen = len.to_s.length
	
	while lenlen < 4
		len = "0"+len.to_s
		lenlen = len.to_s.length
	end
	
	
	
# 	Send file.
	log("Initiating xfer of Access database..")
#	puts data
	socket.write "0030;0044;/mnt/flash/TaskConfig/NewAccessDB;"
		
	message = socket.recv(9000)
	log("Message: "+message)
	fields = message.split(";")
		
	if fields[0] == "1030"
		log("Got OK. Sending file. Len: "+len.to_s)

		while data.size > 4084
			data1 = data.slice!(0..4084)
			newsize = data1.size + 10
			log("File is big. Splitting "+newsize.to_s)
			socket.print("0031;"+newsize.to_s+";"+data1)
			message = socket.recv(9000)
			fields = message.split(";")

			if fields[0] != "1030"
				log("xfer failed!")
				return -1
			end 
		end

		len = data.size + 10
		lenlen = len.to_s.length
	
		while lenlen < 4
			len = "0"+len.to_s
			lenlen = len.to_s.length
		end

		socket.print("0032;"+len.to_s+";"+data)
	end
		
	message = socket.recv(9000)
	log("Message: "+message)
	fields = message.split(";")
		
	if fields[0] == "1030"
		log("File sent successfully.")
		flag += 1
	else
		log("File xfer failed!")
	end
		
		
	db = File.open("/tmp/NewIdentDB-"+$readermac, "r")
	data = db.read
	len = data.size + 10
	lenlen = len.to_s.length
	
	while lenlen < 4
		len = "0"+len.to_s
		lenlen = len.to_s.length
	end
	
	
# 	Send file.
	log("Initiating xfer of Ident database..")
	socket.print("0030;0043;/mnt/flash/TaskConfig/NewIdentDB;")
		
	message = socket.recv(9000)
#	puts "Message: "+message
	fields = message.split(";")
	
	if fields[0] == "1030"
		log("Got OK. Sending file. Len: "+len.to_s)
		while data.size > 4084
			data1 = data.slice!(0..4084)
			newsize = data1.size + 10
			log("File is big. Splitting "+newsize.to_s)
			socket.print("0031;"+newsize.to_s+";"+data1)
			message = socket.recv(9000)
			fields = message.split(";")

			if fields[0] != "1030"
				log("xfer failed!")
				return -1
			end 
		end

		len = data.size + 10
		lenlen = len.to_s.length
	
		while lenlen < 4
			len = "0"+len.to_s
			lenlen = len.to_s.length
		end

		socket.print("0032;"+len.to_s+";"+data)
	end
		
	message = socket.recv(9000)
#	puts "Message: "+message
	fields = message.split(";")
		
	if fields[0] == "1030"
		log("File sent successfully.")
		flag += 1
	else
		log("File xfer failed!")
	end
	
	if flag == 2
		countq = "SELECT COUNT(*) FROM HIDCards"
		countres = sqlq(countq)
		countrow = countres.fetch_row
		estrec = countrow[0]
		estrec = estrec.to_i + 30
		
		lenlen = estrec.to_s.length
	
		while lenlen < 4
			estrec = "0"+estrec.to_s
			lenlen = estrec.to_s.length
			
		end
		log("DB Changeover command sent.")
		socket.write "0052;0015;"+estrec+";"
		
	else
		log("DB Sending failed!")
	end
	
	return flag

end


# send time without having to rebuild the reader details. 
def sendTime(socket)

                # Set the time / date.
                time = Time.new
                timestr = time.strftime("%m;%d;%Y;%H;%M;%S;")
                len = timestr.length
                len = len.to_i
                len = len + 10
                len = len.to_s
                socket.write "0018;00"+len+";"+timestr

                message = socket.recv(9000)
                fields = message.split(";")
                if fields[2] != "0"; log("Setting time unsuccessful!"); return 1; end

                # Set the timezone.
                string = "0088;0018;PST8PDT;"
                socket.write string

                message = socket.recv(9000)
                fields = message.split(";")
                if fields[2] != "0"; log("Setting timezone unsuccessful!"); return 1; end

end



# Method to set the date/time/tz on the reader, configure the reader to
# use its internal database for cards, ask the host about unknown ones.
def newReaderSetup(socket)	
	
		# Set the time / date.
		time = Time.new
		timestr = time.strftime("%m;%d;%Y;%H;%M;%S;")
		len = timestr.length
		len = len.to_i
		len = len + 10
		len = len.to_s
		newstring ="0018;00"+len+";"+timestr
		socket.write newstring
		
		message = socket.recv(9000)
		fields = message.split(";")
		if fields[2] != "0"; log("Setting time unsuccessful!"); return 1; end

		# Set the timezone.
		string = "0088;0018;PST8PDT;"
		socket.write string
		
		message = socket.recv(9000)
		fields = message.split(";")
		if fields[2] != "0"; log("Setting timezone unsuccessful!"); return 1; end
	
	
		# Send the "readers" file.
		log("Initiating xfer..")
		socket.write "0030;0040;/mnt/flash/TaskConfig/Readers;"
		
		message = socket.recv(9000)
		fields = message.split(";")
		
		if fields[0] == "1030"
			log("Got OK. Sending file..")
		
			socket.write "0032;0148;# Readers configuration file
#r IID IF a AM psup pincmd rdrtyp elev apbtyp tmout apbact entryid exitid lkup
1 1 0 0 2 0 0 1 0 0 0 0 0 0 1
"
		end
		
		message = socket.recv(9000)
		fields = message.split(";")
		
		if fields[0] == "1030"
			log("File sent successfully.")
		else
			log("File xfer failed!")
		end
		
		
		# Put a command to restart the reader on the stack.
			$stack << "0012;0013;99;"
	
	
end



# Method to log a message to the syslog.
def log(message)
  # $0 is the current script name
  Syslog.open($0, Syslog::LOG_PID | Syslog::LOG_CONS, facility = Syslog::LOG_DAEMON) { |s| s.info message }
end



x = StdClass.new

