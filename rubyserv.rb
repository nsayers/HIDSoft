#       rubyserv.rb
#
#       Copyright 2026 Neil Sayers
#
#       rev 2.5.1
#

require 'socket'
require 'io/wait'
require 'rubygems'
require 'mysql2'
require 'syslog'
require 'thread'

DB_CONFIG = {
  host:     "127.0.0.1",
  username: "username",
  password: "password",
  database: "HIDSoft"
}.freeze

# Holds all per-child state so forked children and their threads
# don't share mutable globals.
ChildState = Struct.new(
  :stack,
  :readermac,
  :clientip,
  :last_0060_request,
  :awaiting_controller_data,
  :socket_mutex,
  :shutdown
)

# Standard server class. Listens on port 4070 and forks a child for
# each incoming connection.
class StdClass
  def initialize
    log("Startup..")
    debug_flag = ARGV[0] == "debug"
    log("Debug mode enabled, logging will be verbose.") if debug_flag

    $0 = "HIDSoft: Parent"
    server = TCPServer.new("0.0.0.0", 4070)

    while socket = server.accept
      t = fork { ChildProc(socket, debug_flag) }
      Process.detach(t)
    end
  end
end

# Open a fresh DB connection. Callers are responsible for closing it.
def db_connect
  Mysql2::Client.new(DB_CONFIG)
  rescue Mysql2::Error => e
  raise if retries == 0
  log("DB connect failed (#{e.message}), retrying in 5s (#{retries} left)")
  sleep 5
  retry
end

def sqlq(client, sql, *params)
  stmt = client.prepare(sql)
  result = stmt.execute(*params)
  result.to_a if result
  result
  rescue Mysql2::Error => e
    log("DB error #{e.errno}: #{e.message}")
  nil
end

def sqlq_once(sql, *params)
  client = db_connect
  sqlq(client, sql, *params)

  ensure
    client&.close
end



# The main child process.
def ChildProc(newsocket, debug_flag)
  i = 0
  st = ChildState.new(
    [],           # stack
    nil,          # readermac
    nil,          # clientip
    Time.at(0),   # last_0060_request
    false,        # awaiting_controller_data
    Mutex.new,    # socket_mutex
    false         # shutdown
  )

  cli_addr  = newsocket.peeraddr
  st.clientip = cli_addr[3]
  log("New connection from #{st.clientip}")
  $0 = "HIDSoft: Child #{st.clientip}"

  db = db_connect
  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "Child Process started for #{st.clientip}", '4')

  while i < 240
    if newsocket.ready?
      break if st.shutdown
      i = 0
      message = newsocket.recv(9000)
      fields  = message.split(";")
      flag    = 1

      while flag == 1
        case fields[0]

        # Initial handshake — reader sends its MAC address.
        when "1042"
          st.readermac = fields[2]
          st.stack << "0070;0010;"
          unless st.awaiting_controller_data
            st.stack << "0060;0010;"
            st.last_0060_request      = Time.now
            st.awaiting_controller_data = true
          end
          len     = fields[1].to_i
          message = message[len..9000]
          fields  = message.split(";")
          flag    = 0 if fields[0].nil?

        # Heartbeat.
        when "1080"
          sqlq(db, "INSERT INTO HIDActive SET mac = ?, ip = ?, timestamp = NOW() " \
                   "ON DUPLICATE KEY UPDATE mac = ?, ip = ?, timestamp = NOW()",
               st.readermac, st.clientip, st.readermac, st.clientip)
          st.stack << "0080;0010;"
          len     = fields[1].to_i
          message = message[len..9000]
          fields  = message.split(";")
          flag    = 0 if fields[0].nil?

        # Card lookup — real-time access decision.
        when "1073"
          st.stack << "0073;0012;0;"
          len = fields[1].to_i
          Thread.new do
            thread_db = db_connect
            begin
              ParseCard(message, newsocket, st, thread_db)
            ensure
              thread_db&.close
            end
          end
          message = message[len..9000]
          fields  = message.split(";")

        # Log messages from the reader.
        when "1065", "1060", "1061"
          st.stack << "0067;0010;"
          clean = strip_header(message)
          if clean
            Thread.new do
              thread_db = db_connect
                begin
                  ParseMsg(clean, fields[0], st, thread_db)
                ensure
                  thread_db&.close
                end
              end
            end
          flag = 0

        when "1062"
          st.awaiting_controller_data = false
          clean = strip_header(message)
          Thread.new { ParseMsg(clean, fields[0], st, db) } if clean && clean.length > 2
          len     = fields[1].to_i
          message = message[len..9000]
          fields  = message.split(";")
          flag    = 0 if fields[0].nil? || fields[0].empty?

        # Reader confirms indexed files — tell it to make them active.
        when "1107"
          if fields[2] == "0"
            sleep 20
            sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                 st.clientip, 'LogMsg 1070: Reporting properly indexed files, reloading database files!', '3')
            st.stack << "0108;0010;"
          else
            sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                 st.clientip, 'LogMsg 1070: Reporting indexed files failed!', '1')
          end

        # DB changeover acknowledgement.
        when "1052"
          if fields[2] == "0"
            sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                 st.clientip, 'LogMsg 1052: DB Changeover completed', '3')
            sqlq(db, "UPDATE HIDReaders SET changeover = CURRENT_TIMESTAMP WHERE mac = ?", st.readermac)
            sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
          else
            sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                 st.clientip, "LogMsg 1052: DB Changeover failed with #{fields[2]}, restarting push", '1')
            sqlq(db, "UPDATE HIDReaders SET manual_open = '200' WHERE mac = ?", st.readermac)
          end
          flag = 0

        when nil, ""
          flag = 0

        else
          sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, "Undefined Log message: #{message}", '3')
          log("Received: #{message}")
          flag = 0
        end

        # Flush one item from the stack to the socket.
        flush_stack(newsocket, st, db)
      end

    else
      # Socket not ready — idle tick.
      i += 1

      if st.readermac &&
         !st.awaiting_controller_data &&
         (Time.now - st.last_0060_request) >= 60

        #sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
        #     st.clientip, 'Requesting current controller messages (0060)', '4')
        st.stack << "0060;0010;"
        st.last_0060_request        = Time.now
        st.awaiting_controller_data = true
      end

      flush_stack(newsocket, st, db)

      if st.readermac && (i % 10 == 0)
        chkManualOverride(newsocket, st, db)
      end

      if st.readermac && i == 10
        ChkTimeSync(newsocket, st, db)
      end
    end

    sleep 0.25
  end

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "Detected lost connection from #{st.clientip}. Exiting.", '4')
  log("Detected lost connection from #{st.clientip}. Exiting.")
  newsocket.close

  ensure
    db&.close
end

################################################
##
## Defined processes and steps
##

def checkActiveNeed(socket, st, db)
  res = sqlq(db,
    "SELECT HIDActive.mac, " \
    "UNIX_TIMESTAMP(HIDActive.accessdb), " \
    "UNIX_TIMESTAMP(HIDActive.identdb), " \
    "UNIX_TIMESTAMP(HIDReaders.changeover) " \
    "FROM HIDActive " \
    "INNER JOIN HIDReaders ON HIDActive.mac = HIDReaders.mac " \
    "WHERE HIDActive.mac = ?",
    st.readermac)

  rows = res&.to_a
  return if rows.nil? || rows.empty?

  row = rows.first
  return unless row

  ten_minutes = 600
  two_hours   = 7200
  now         = Time.now.to_i

  if (row[3].to_i - row[1].to_i) > ten_minutes
    log("AccessDB is not within 10 minutes of Changeover")
    sqlq(db, "UPDATE HIDReaders SET manual_open = '240' WHERE mac = ?", st.readermac)
    return
  end

  if (row[3].to_i - row[2].to_i) > ten_minutes
    log("IdentDB is not within 10 minutes of Changeover")
    sqlq(db, "UPDATE HIDReaders SET manual_open = '250' WHERE mac = ?", st.readermac)
    return
  end

  if (now - row[3].to_i) > two_hours
    log("Time to update the reader")
    sqlq(db, "UPDATE HIDReaders SET manual_open = '200' WHERE mac = ?", st.readermac)
    return
  end

  sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
end

def chkManualOverride(socket, st, db)
  res = sqlq(db, "SELECT manual_open, cmd, ftp, failcount FROM HIDReaders WHERE mac = ?",
             st.readermac)
  rows = res&.to_a
  if rows.nil? || rows.empty?
    sqlq(db, "INSERT INTO HIDReaders (mac, groups, comment, manual_open, cmd) VALUES (?, '35', 'Reader-#{st.readermac}', '0', '100')",
         st.readermac)
    return
  end

  row = rows.first
  manual_open = row["manual_open"].to_i
  cmd         = row["cmd"].to_i
  ftp         = row["ftp"].to_i
  failcount   = row["failcount"].to_i

  # cmd-based tasks (separate from manual_open)
  case cmd
  when 52
    sleep 5
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Task: Database changeover command called', '3')
    SendDBChange(socket, st, db)
  when 100
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Task: New Reader setup called', '3')
    SetTime(socket, st, db)
    GetInternalID(socket, st, db)
    SendAccessGroups(socket, st, db)
    SendCfgFile(socket, st, db)
    SendDoorGroups(socket, st, db)
    Sendeeprom(socket, st, db)
    SendEventMsg(socket, st, db)
    SendHolidays(socket, st, db)
    SendInternalID(socket, st, db)
    SendInterfaceBoards(socket, st, db)
    SendInterfaceTypes(socket, st, db)
    SendIOLinker(socket, st, db)
    SendReaders(socket, st, db)
    SendSchedule(socket, st, db)
    SendAccessDB(socket, st, db)
    SendIdentDB(socket, st, db)
    SendDBChange(socket, st, db)
    sqlq(db, "UPDATE HIDReaders SET cmd = '0' WHERE mac = ?", st.readermac)
  end


  case manual_open
  when 1
    st.stack << "0094;0016;0;7;2;"
    sqlq(db, "INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'GRANT', 'Manual Admit')",
         st.readermac)
    sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 187
    log("Reader reboot requested")
    sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    st.stack << "0096;0013;32;"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message) VALUES (?, 'Reader Reboot requested')",
         st.readermac)

  when 200
    st.stack << "0012;0013;99;"
    if ftp == 1 || failcount == 5
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, 'Task: AccessDB/IdentDB refresh called. FTP called', '3')
      sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
      transferDB(socket, st, db)
      sqlq(db, "UPDATE HIDReaders SET manual_open = '500' WHERE mac = ?", st.readermac)
    else
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, 'Task: AccessDB/IdentDB refresh called. HID linker called', '3')
      sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
      SendIdentDB(socket, st, db)
      SendAccessDB(socket, st, db)
      sleep 5
      sqlq(db, "UPDATE HIDReaders SET manual_open = '500' WHERE mac = ?", st.readermac)
    end

  when 240
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Task: AccessDB refresh only called', '3')
    SendAccessDB(socket, st, db)
    st.stack << "0012;0012;9;"
    sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 250
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Task: IdentDB refresh only called', '3')
    SendIdentDB(socket, st, db)
    st.stack << "0012;0012;9;"
    sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 300
    system("/usr/local/sbin/HIDSoft/bin/buildsch.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildiol.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildho.pl", st.readermac)
    sleep 1
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Task: Schedule/IOLinker/Holiday refresh called', '3')
    sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    SendSchedule(socket, st, db)
    sleep 1
    SendHolidays(socket, st, db)
    sleep 1
    SendIOLinker(socket, st, db)
    st.stack << "0012;0012;5;"

  when 500
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Task: Database changeover command called', '3')
    SendDBChange(socket, st, db)

  when 501
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Task: IOLinker Reset', '3')
    sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    st.stack << "0012;0012;5;"

  when 666
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Task: Reader reboot request', '3')
    sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    st.stack << "0012;0013;99;"

  when 900
    log("Calling InternalID grab")
    GetInternalID(socket, st)
    sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 999
    sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Task: Full Configuration called', '3')
    system("/usr/local/sbin/HIDSoft/bin/builddb.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildsch.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildho.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildiol.pl", st.readermac)
    SendAccessDB(socket, st, db)
    sleep 1
    SendIdentDB(socket, st, db)
    sleep 1
    SendDBChange(socket, st, db)
    sleep 1
    SendSchedule(socket, st, db)
    SendHolidays(socket, st, db)
    sleep 1
    st.stack << "0012;0013;99;"
  end
end

def ChkTimeSync(socket, st, db)
  res = sqlq(db, "SELECT UNIX_TIMESTAMP(lasttimesync) as ts FROM HIDReaders WHERE mac = ?",
             st.readermac)
  row = res&.first
  return unless row

  db_time = row["ts"].to_i
  threshold = Time.now.to_i - 600   # 10 minutes

  if threshold > db_time
    SetTime(socket, st, db)
    sqlq(db, "UPDATE HIDReaders SET lasttimesync = NOW() WHERE mac = ?", st.readermac)
  end
end

def flush_stack(socket, st, db)
  return if st.stack.empty?
  item = st.stack.shift
  if item == "sleep"
    sleep 0.5
  else
    st.socket_mutex.synchronize do
      socket.write(item)
    end
  end
  rescue => e
    log("Socket write error: #{e.message}")
    st.shutdown = true
end

def ftpReader(socket, st, db)
  time      = Time.new
  timeinsert = time.strftime("%Y-%m-%d %k:%M:%S")
  system("/usr/local/sbin/HIDSoft/bin/deployftp.sh", st.readermac)
  sqlq(db, "UPDATE HIDReaders SET lasttimesync = ? WHERE mac = ?", timeinsert, st.readermac)
end

def GetInternalID(socket, st)
  path = "/mnt/flash/TaskConfig/InternalID"
  cmd = "0033;#{pad4(path.length + 10)};#{path};"
  log("InternalID: >>> #{cmd}")
  safe_write(socket, cmd, st)
  data = +""

  loop do
    message = socket.recv(9000)
    if message.nil? || message.empty?
      log("InternalID: no response from controller")
      return nil
    end

    log("InternalID: <<< #{message.inspect}")
    first  = message.index(";")
    second = message.index(";", first + 1)

    unless first && second
      log("InternalID: malformed response #{message.inspect}")
      return nil
    end

    code  = message[0...first]
    len   = message[(first + 1)...second]
    chunk = message[(second + 1)..-1]
    chunk ||= ""
    log("InternalID: code=#{code} len=#{len} chunk.bytes=#{chunk.bytesize}")
    case code

    when "1033"   # GET_FILE_MORE
      data << chunk
      log("InternalID: accumulated #{data.bytesize} bytes")
      safe_write(socket, "0034;0010;", st)

    when "1034"   # GET_FILE_END
      data << chunk
      log("InternalID raw:\n#{data}")
      updated = data.gsub(/^INTID=.*$/, "INTID=1")
      filename = "/usr/local/sbin/HIDSoft/bin/InternalID-#{st.readermac}"
      File.write(filename, data)
      log("InternalID: saved to #{filename}")
      return updated

    when "1080"   # heartbeat
      safe_write(socket, "0080;0010;", st)

    else
      log("InternalID: unexpected response #{message.inspect}")
      return nil
    end
  end
end

def newReaderSetup(socket, st, db)
  SetTimezone(socket, st, db)
  SetTime(socket, st, db)

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'New Reader setup called', '3')
  safe_write(socket, "0030;0040;/mnt/flash/TaskConfig/Readers;", st)

  message = recv_expect(socket, "1030", st, db, "Readers VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'Readers: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("Readers: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Readers: Error, xfer in progress.', '2')
    sleep 5
    safe_write(socket, "0030;0040;/mnt/flash/TaskConfig/Readers;", st)
  end

  if fields[0] == "1030"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Reader: Got OK, sending default reader settings', '3')
    safe_write(socket,
      "0032;0148;# Readers configuration file\n" \
      "#r IID IF a AM psup pincmd rdrtyp elev apbtyp tmout apbact entryid exitid lkup\n" \
      "1 1 0 0 2 0 0 1 0 0 0 0 0 0 1\n",
      st)
  end

  message = recv_expect(socket, "1030", st, db, "Readers chunk #{chunk_count}")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Readers: unexpected response to chunk #{chunk_count}, aborting", '1')
    return
  end
  log("Readers: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "1030"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Readers: File sent successfully!', '3')
  else
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Readers: Error, xfer failed. Please check with admin', '1')
  end

  st.stack << "0012;0013;99;"
end

def pad4(n)
  n.to_s.rjust(4, '0')
end

def ParseCard(msg, socket, st, db)
  fields  = msg.split(";")
  card_num = fields[13]
  mac      = fields[10]

  safe_write(socket, "0094;0016;0;9;0;", st)

  res = sqlq(db, "SELECT groupid, id FROM HIDCards " \
                 "WHERE cardnum = ? " \
                 "AND (expires IS NULL OR expires > NOW()) " \
                 "AND (deleted IS NULL OR deleted > NOW()) " \
                 "ORDER BY lastupdate DESC",
             card_num)

  rows = res&.to_a
  if rows.nil? || rows.empty?
    log("No card record found.")
    sqlq(db, "INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-UNKWN', ?)",
         st.readermac, card_num)
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Card #{card_num} unknown, please check card assignment", '3')
    safe_write(socket, "0094;0016;0;8;2;", st)
    return
  end

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "Card record found, checking permissions for #{card_num}", '4')
  card_row = rows.first

  reader_res = sqlq(db, "SELECT groups FROM HIDReaders WHERE mac = ?", mac)
  reader_rows = reader_res&.to_a

  if reader_rows.nil? || reader_rows.empty?
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Reader permission issue, please contact an Admin', '1')
    return
  end

  groups = reader_rows.first["groups"].to_s.split(",")

  if groups.include?(card_row["groupid"].to_s)
    sqlq(db, "INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'GRANT', ?)",
         st.readermac, card_num)
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Card #{card_num} granted", '2')
    safe_write(socket, "0094;0016;0;7;2;", st)
  else
    sqlq(db, "INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-NOACC', ?)",
         st.readermac, card_num)
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Card #{card_num} denied, no access rights for door #{st.clientip}", '3')
    safe_write(socket, "0094;0016;0;8;2;", st)
  end
end

def parseCheckCard(msg, socket, st, db)
  fields = msg.split(";")
  safe_write(socket, "0094;0016;0;9;0;", st)

  res = sqlq(db, "SELECT groupid, contact_id, id FROM HIDCards " \
                 "WHERE cardnum = ? AND (expires IS NULL OR expires > NOW())",
             fields[2])
  return unless res

  row = res.to_a
  if row.empty?
    log("No card record found.")
    sqlq(db, "INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-UNKWN', ?)",
         st.readermac, fields[2])
    safe_write(socket, "0094;0016;0;8;2;", st)
    return
  end

  reader_res = sqlq(db, "SELECT groups FROM HIDReaders WHERE mac = ?", st.readermac)
  return unless reader_res

  reader_rows = reader_res.to_a
  return if reader_rows.empty?

  card_row = row.first
  groups   = reader_rows.first["groups"].to_s.split(",")

  if groups.include?(card_row["groupid"].to_s)
    sqlq(db, "INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'GRANT', ?)",
         st.readermac, fields[2])
    log("Granting access to #{fields[2]}")
    safe_write(socket, "0094;0016;0;7;2;", st)
  else
    sqlq(db, "INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-NOACC', ?)",
         st.readermac, fields[2])
    log("Deny access to #{fields[2]}")
    safe_write(socket, "0094;0016;0;8;2;", st)
  end
end

def ParseMsg(msg, event_type, st, db)
  msg = msg.gsub(/  +/, ' ')
  log("Message details: #{msg}")
  newmsg = msg.split("^").reject(&:empty?)
  return if newmsg.empty?
  fields = newmsg[0].split(";")

  while newmsg[0]
    info0  = fields[0]
    info2  = fields[2]
    info3  = fields[3]
    info4  = fields[4]
    info5  = fields[5]
    info9  = fields[9]
    info10 = fields[10]
    info11 = fields[11]
    info13 = fields[13]

    if ARGV[0] == "debug"
      log("event: #{event_type}")
      log("Event/alarm: #{info0}")
      log("Type: #{info2}")
      log("Class Code: #{info3}")
      log("Task Code: #{info4}")
      log("Event Code: #{info5}")
      log("Priority Code: #{fields[6]}")
      log("Time: #{fields[7]}")
      log("MAC: #{fields[8]}")
      log("X1: #{info9}")  if info9
      log("X2: #{info10}") if info10
      log("X3: #{fields[11]}") if fields[11]
      log("X4: #{fields[12]}") if fields[12]
      log("X5: #{info13}") if info13
    end

    time_field = fields.find { |f| f =~ /\d{2}:\d{2}:\d{2}/ }
    date_field = fields.find { |f| f =~ /\d{2}\/\d{2}\/\d{4}/ }

    if time_field && date_field
      time_val = time_field[/\d{2}:\d{2}:\d{2}/]
      date_val = date_field[/\d{2}\/\d{2}\/\d{4}/]
      parts    = date_val.split("/")
      timestamp = "#{parts[2]}-#{parts[0]}-#{parts[1]} #{time_val}"

      if info0 == "1060"
        if info4 == "2" && info2 == "1"
          task_code = {
            "20" => "GRANT",
            "21" => "GRANT-EXTENDED",
            "23" => "DENY-NOACC",
            "24" => "DENY-SCHEDULE",
            "25" => "DENY-UNKRDR",
            "27" => "DENY-DELETED",
            "29" => "DENY-PIN",
            "30" => "DENY-TIMED-ANTIPASSBACK",
            "31" => "DENY-REAL-ANTIPASSBACK",
            "32" => "DENY-AREAVIOLATION",
            "33" => "DENY-REAL-ANTIPASSBACK-EXIT",
            "34" => "DENY-AREAVIOLATION-EXIT",
            "35" => "DENY-DOORGROUP-SCHEDULEERROR",
            "36" => "DENY-EXPIRE",
            "37" => "GRANT-ELEVATOR-INSCHEDULE",
            "38" => "GRANT-ELEVATOR-INSCHEDULE"
          }[info5] || "UNKNOWN-CODE"
          sqlq(db, "INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES (?, ?, ?, ?)",
               st.readermac, task_code, info11, timestamp)
        elsif info3 == "4"
          if info9 == "901"
            if info10 == "1"
              sqlq(db, "INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES (?, 'ALARM', 'DOOR HAS BEEN FORCED', ?)",
                   st.readermac, timestamp)
              sqlq(db, "UPDATE HIDAlarm SET alarm = '1' WHERE id = '1'")
              st.stack << "0094;0017;0;11;0;"
            elsif info10 == "0"
              st.stack << "0094;0017;0;11;1;"
            end
          elsif info9 == "903"
            if info10 == "1"
              sqlq(db, "INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES (?, 'HELD', 'DOOR HAS BEEN HELD', ?)",
                   st.readermac, timestamp)
              st.stack << "0094;0017;0;11;0;"
            elsif info10 == "0"
              st.stack << "0094;0017;0;11;1;"
            end
          end
        end
      end
    else
      log("Skipping frame with no timestamp: #{info0} (#{fields.inspect})")
    end

    newmsg.shift
    break if newmsg.empty?
    begin
      fields = newmsg[0].split(";")
    rescue => e
      log("ParseMsg: failed to parse next frame: #{e.message}")
      break
    end
  end
end

def SendAccessDB(socket, st, db)
  path = "/usr/local/sbin/HIDSoft/bin/NewAccessDB-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/NOC-AccessDB"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("AccessDB file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  log("Initiating xfer of Access database..")
  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'AccessDB: Initiate xfer of AccessDB file', '3')

  cmd = "0030;0044;/mnt/flash/TaskConfig/NewAccessDB;"
  log("AccessDB: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "AccessDB VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'AccessDB: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("AccessDB: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'AccessDB: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0044;/mnt/flash/TaskConfig/NewAccessDB;", st)

    message = recv_expect(socket, "1030", st, db, "AccessDB RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("AccessDB: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "AccessDB: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("AccessDB: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("AccessDB: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "AccessDB chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "AccessDB: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("AccessDB: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("AccessDB: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "AccessDB: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("AccessDB: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "AccessDB VERTX_SEND_DATA_END")
  log("AccessDB: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("AccessDB: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "AccessDB: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("AccessDB: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "AccessDB: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("AccessDB: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "AccessDB: Connection lost during transfer: #{e.message}", '1')
end

def SendAccessGroups(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/AccessGroups-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/AccessGroups"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("AccessGroups file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'AccessGroups: Initiate xfer of AccessGroups file', '3')
  cmd = "0030;0042;/mnt/flash/TaskConfig/AccessGroups;"
  log("AccessGroups: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "AccessGroups VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'AccessGroups: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("AccessGroups: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'AccessGroups: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0043;/mnt/flash/TaskConfig/AccessGroups;", st)

    message = recv_expect(socket, "1030", st, db, "AccessGroups RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("AccessGroups: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "AccessGroups: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("AccessGroups: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("AccessGroups: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "AccessGroups chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "AccessGroups: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("AccessGroups: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("AccessGroups: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "AccessGroups: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("AccessGroups: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "AccessGroups VERTX_SEND_DATA_END")
  log("AccessGroups: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("AccessGroups: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "AccessGroups: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("AccessGroups: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "AccessGroups: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("AccessGroups: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "AccessGroups: Connection lost during transfer: #{e.message}", '1')
end

def SendCfgFile(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/CfgFile-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/CfgFile"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("CfgFile file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'CfgFile: Initiate xfer of CfgFile file', '3')
  cmd = "0030;0042;/mnt/flash/TaskConfig/CfgFile;"
  log("CfgFile: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "CfgFile VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'CfgFile: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("CfgFile: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'CfgFile: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0043;/mnt/flash/TaskConfig/CfgFile;", st)

    message = recv_expect(socket, "1030", st, db, "CfgFile RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("CfgFile: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "CfgFile: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("CfgFile: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("CfgFile: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "CfgFile chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "CfgFile: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("CfgFile: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("CfgFile: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "CfgFile: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("CfgFile: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "CfgFile VERTX_SEND_DATA_END")
  log("CfgFile: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("CfgFile: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "CfgFile: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("CfgFile: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "CfgFile: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("CfgFile: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "CfgFile: Connection lost during transfer: #{e.message}", '1')
end

def SendDBChange(socket, st, db)
  sqlq(db, "UPDATE HIDReaders SET cmd = '0' WHERE mac = ?", st.readermac)
  safe_write(socket, "0052;0015;2000;", st)

  message = recv_expect(socket, "1052", st, db, "SendDBChange")
  return unless message
  log("Message: #{message}")
  fields = message.split(";")

  if fields[0] == "1052"
    if fields[2] == "0"
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, 'LogMsg 1052: DB Changeover completed', '3')
      sqlq(db, "UPDATE HIDReaders SET changeover = CURRENT_TIMESTAMP WHERE mac = ?",
           st.readermac)
    else
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "LogMsg 1052: DB Changeover failed with #{fields[2]}, manual review required", '1')
      sqlq(db, "UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    end
  end
end

def SendDoorGroups(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/DoorGroups-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/DoorGroups"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("DoorGroups file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'DoorGroups: Initiate xfer of DoorGroups file', '3')
  cmd = "0030;0042;/mnt/flash/TaskConfig/DoorGroups;"
  log("DoorGroups: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "DoorGroups VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'DoorGroups: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("DoorGroups: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'DoorGroups: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0043;/mnt/flash/TaskConfig/DoorGroups;", st)

    message = recv_expect(socket, "1030", st, db, "DoorGroups RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("DoorGroups: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "DoorGroups: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("DoorGroups: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("DoorGroups: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "DoorGroups chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "DoorGroups: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("DoorGroups: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("DoorGroups: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "DoorGroups: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("DoorGroups: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "DoorGroups VERTX_SEND_DATA_END")
  log("DoorGroups: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("DoorGroups: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "DoorGroups: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("DoorGroups: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "DoorGroups: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("DoorGroups: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "DoorGroups: Connection lost during transfer: #{e.message}", '1')
end

def Sendeeprom(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/eeprom.properties-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/eeprom.properties"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("eeprom.properties file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'eeprom: Initiate xfer of eeprom file', '3')
  cmd = "0030;0042;/mnt/flash/TaskConfig/eeprom.properties;"
  log("eeprom: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "eeprom VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'eeprom: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("eeprom: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'eeprom: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0043;/mnt/flash/TaskConfig/eeprom.properties;", st)

    message = recv_expect(socket, "1030", st, db, "eeprom.properties RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("eeprom: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "eeprom: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("eeprom: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("eeprom: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "eeprom chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "eeprom: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("eeprom: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("eeprom: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "eeprom: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("eeprom: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "eeprom VERTX_SEND_DATA_END")
  log("eeprom: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("eeprom: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "eeprom: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("eeprom: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "eeprom: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("eeprom: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "eeprom: Connection lost during transfer: #{e.message}", '1')
end

def SendEventMsg(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/EventMsg-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/EventMsg"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("EventMsg file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'EventMsg: Initiate xfer of EventMsg file', '3')
  cmd = "0030;0042;/mnt/flash/TaskConfig/EventMsg;"
  log("EventMsg: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "EventMsg VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'EventMsg: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("EventMsg: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'EventMsg: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0043;/mnt/flash/TaskConfig/EventMsg;", st)

    message = recv_expect(socket, "1030", st, db, "EventMsg RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("EventMsg: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "EventMsg: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("EventMsg: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("EventMsg: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "EventMsg chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "EventMsg: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("EventMsg: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("EventMsg: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "EventMsg: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("EventMsg: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "EventMsg VERTX_SEND_DATA_END")
  log("EventMsg: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("EventMsg: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "EventMsg: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("EventMsg: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "EventMsg: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("EventMsg: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "EventMsg: Connection lost during transfer: #{e.message}", '1')
end

def SendHolidays(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/Holidays-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/Holidays"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("Holidays file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'Holiday: Initiate xfer of Holidays file', '3')
  cmd = "0030;0041;/mnt/flash/TaskConfig/Holidays;"
  log("Holidays: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "Holidays VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'Holidays: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("Holidays: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Holiday: Error, xfer in progress.', '2')
    sleep 5
    safe_write(socket, "0030;0041;/mnt/flash/TaskConfig/Holidays;", st)

    message = recv_expect(socket, "1030", st, db, "Holidays RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("Holidays: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Holidays: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("Holidays: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("Holidays: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "Holidays chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Holidays: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("Holidays: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("Holidays: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Holidays: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("Holidays: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "Holidays VERTX_SEND_DATA_END")
  log("Holidays: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("Holidays: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Holidays: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("Holidays: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Holidays: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("Holidays: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "Holidays: Connection lost during transfer: #{e.message}", '1')
end

def SendIdentDB(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/NewIdentDB-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/NOC-IdentDB"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("CfgFile file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'IdentDB: Initiate xfer of IdentDB file', '3')
  cmd = "0030;0043;/mnt/flash/TaskConfig/NewIdentDB;"
  log("IdentDB: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "IdentDB VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'IdentDB: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("IdentDB: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'IdentDB: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0043;/mnt/flash/TaskConfig/NewIdentDB;", st)

    message = recv_expect(socket, "1030", st, db, "CfgFile RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("IdentDB: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "IdentDB: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("IdentDB: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("IdentDB: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "IdentDB chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "IdentDB: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("IdentDB: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("IdentDB: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "IdentDB: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("IdentDB: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "IdentDB VERTX_SEND_DATA_END")
  log("IdentDB: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("IdentDB: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "IdentDB: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("IdentDB: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "IdentDB: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("IdentDB: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "IdentDB: Connection lost during transfer: #{e.message}", '1')
end

def SendInternalID(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/InternalID-#{st.readermac}"
  unless File.exist?(path)
    log("InternalID: cache miss for #{st.readermac}, pulling from controller")
    data = GetInternalID(socket, st)
    unless data
      log("InternalID: controller fetch failed for #{st.readermac}")
      return
    end
  end

  data = File.read(path)
  log("InternalID file=#{path} File.size=#{File.size(path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'InternalID: Initiate xfer of InternalID file', '3')
  cmd = "0030;0042;/mnt/flash/TaskConfig/InternalID;"
  log("InternalID: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "InternalID VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'InternalID: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("InternalID: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'InternalID: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0043;/mnt/flash/TaskConfig/InternalID;", st)
  end

  unless fields[0] == "1030"
    log("InternalID: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "InternalID: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("InternalID: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("InternalID: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "InternalID chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "InternalID: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("InternalID: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("InternalID: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "InternalID: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("InternalID: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "InternalID VERTX_SEND_DATA_END")
  log("InternalID: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("InternalID: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "InternalID: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("InternalID: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "InternalID: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("InternalID: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "InternalID: Connection lost during transfer: #{e.message}", '1')
end

def SendInterfaceBoards(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/InterfaceBoards-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/InterfaceBoards"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("InterfaceBoards file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'InterfaceBoards: Initiate xfer of InterfaceBoards file', '3')
  cmd = "0030;0042;/mnt/flash/TaskConfig/InterfaceBoards;"
  log("InterfaceBoards: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "InterfaceBoards VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'InterfaceBoards: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("InterfaceBoards: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'InterfaceBoards: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0043;/mnt/flash/TaskConfig/InterfaceBoards;", st)

    message = recv_expect(socket, "1030", st, db, "InterfaceBoards RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("InterfaceBoards: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "InterfaceBoards: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("InterfaceBoards: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("InterfaceBoards: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "InterfaceBoards chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "InterfaceBoards: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("InterfaceBoards: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("InterfaceBoards: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "InterfaceBoards: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("InterfaceBoards: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "InterfaceBoards VERTX_SEND_DATA_END")
  log("InterfaceBoards: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("InterfaceBoards: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "InterfaceBoards: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("InterfaceBoards: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "InterfaceBoards: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("InterfaceBoards: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "InterfaceBoards: Connection lost during transfer: #{e.message}", '1')
end

def SendInterfaceTypes(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/InterfaceTypes-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/InterfaceTypes"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("InterfaceTypes file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'InterfaceTypes: Initiate xfer of InterfaceTypes file', '3')
  cmd = "0030;0042;/mnt/flash/TaskConfig/InterfaceTypes;"
  log("InterfaceTypes: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "InterfaceTypes VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'InterfaceTypes: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("InterfaceTypes: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'InterfaceTypes: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0043;/mnt/flash/TaskConfig/InterfaceTypes;", st)

    message = recv_expect(socket, "1030", st, db, "InterfaceTypes RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("InterfaceTypes: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "InterfaceTypes: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("InterfaceTypes: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("InterfaceTypes: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "InterfaceTypes chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "InterfaceTypes: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("InterfaceTypes: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("InterfaceTypes: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "InterfaceTypes: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("InterfaceTypes: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "InterfaceTypes VERTX_SEND_DATA_END")
  log("InterfaceTypes: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("InterfaceTypes: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "InterfaceTypes: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("InterfaceTypes: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "InterfaceTypes: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("InterfaceTypes: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "InterfaceTypes: Connection lost during transfer: #{e.message}", '1')
end

def SendIOLinker(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/IOLinkerRules-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/IOLinkerRules"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("IOLinkerRules file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'IOLinkerRule: Initiate xfer of IOLinkerRules file', '3')
  cmd = "0030;0046;/mnt/flash/TaskConfig/IOLinkerRules;"
  log("IOLinkerRules: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "IOLinkerRules VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'IOLinkerRules: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("IOLinkerRules: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'IOLinkerRule: Error, xfer in progress.', '2')
    sleep 5
    safe_write(socket, "0030;0046;/mnt/flash/TaskConfig/IOLinkerRules;", st)

    message = recv_expect(socket, "1030", st, db, "IOLinkerRules RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("IOLinkerRules: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "IOLinkerRules: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("IOLinkerRules: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("IOLinkerRules: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "IOLinkerRules chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "IOLinkerRules: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("IOLinkerRules: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("IOLinkerRules: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "IOLinkerRules: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("IOLinkerRules: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "IOLinkerRules VERTX_SEND_DATA_END")
  log("IOLinkerRules: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("IOLinkerRules: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "IOLinkerRules: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("IOLinkerRules: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "IOLinkerRules: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("IOLinkerRules: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "IOLinkerRules: Connection lost during transfer: #{e.message}", '1')
end

def SendReaders(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/Readers-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/Readers"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("Readers file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'Readers: Initiate xfer of Readers file', '3')
  cmd = "0030;0042;/mnt/flash/TaskConfig/Readers;"
  log("Readers: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "Readers VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'Readers: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("Readers: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Readers: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0043;/mnt/flash/TaskConfig/Readers;", st)

    message = recv_expect(socket, "1030", st, db, "Readers RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("Readers: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Readers: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("Readers: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("Readers: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "Readers chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Readers: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("Readers: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("Readers: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Readers: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("Readers: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "Readers VERTX_SEND_DATA_END")
  log("Readers: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("Readers: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Readers: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("Readers: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Readers: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("Readers: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "Readers: Connection lost during transfer: #{e.message}", '1')
end

def SendSchedule(socket, st, db)
  path    = "/usr/local/sbin/HIDSoft/bin/Schedules-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/Schedules"
  file_path = File.exist?(path) ? path : fallback
  data = File.read(file_path)
  log("Schedules file=#{file_path} File.size=#{File.size(file_path)} data.size=#{data.size} data.bytesize=#{data.bytesize} encoding=#{data.encoding}")

  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'Schedule: Initiate xfer of Schedules file', '3')
  cmd = "0030;0042;/mnt/flash/TaskConfig/Schedules;"
  log("Schedules: >>> sending VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, db, "Schedules VERTX_SEND_FILE")
  unless message
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, 'Schedules: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("Schedules: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields  = message.split(";")

  if fields[0] == "9980"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Schedule: Error, xfer in progress.', '3')
    sleep 5
    safe_write(socket, "0030;0042;/mnt/flash/TaskConfig/Schedules;", st)

    message = recv_expect(socket, "1030", st, db, "Schedules RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    log("Schedules: unexpected response to VERTX_SEND_FILE, expected 1030 got #{fields[0].inspect}, aborting")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Schedules: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  log("Schedules: got 1030, proceeding with data transfer. data.size=#{data.size}")
  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk      = data.slice!(0, 4084)
    newsize    = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("Schedules: >>> sending chunk #{chunk_count} VERTX_SEND_DATA_CONTINUE 0031;#{newsize}; chunk.bytesize=#{chunk.bytesize} data.size remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, db, "Schedules chunk #{chunk_count}")
    unless message
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Schedules: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    log("Schedules: <<< response to chunk #{chunk_count}: #{message.inspect} fields=#{message.split(';').inspect}")
    fields = message.split(";")
    unless fields[0] == "1030"
      log("Schedules: unexpected response to chunk #{chunk_count}, expected 1030 got #{fields[0].inspect}, aborting")
      sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Schedules: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("Schedules: >>> sending final chunk #{chunk_count} VERTX_SEND_DATA_END 0032;#{len}; data.bytesize=#{data.bytesize} total_bytes_sent=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, db, "Schedules VERTX_SEND_DATA_END")
  log("Schedules: <<< response to VERTX_SEND_DATA_END: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "1030"
    log("Schedules: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Schedules: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("Schedules: transfer failed. final response=#{message.inspect}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, "Schedules: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
  rescue IOError, Errno::ECONNRESET => e
    log("Schedules: connection lost: #{e.message} backtrace=#{e.backtrace.first}")
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "Schedules: Connection lost during transfer: #{e.message}", '1')
end

def SetTime(socket, st, db)
  time    = Time.new
  # Format: MM;DD;YYYY;HH;MM;SS;
  timestr = time.strftime("%m;%d;%Y;%H;%M;%S;")
  # +10 for the "0018;XXXX;" header (8 chars + 2 semicolons)
  len     = pad4(timestr.length + 10)
  cmd     = "0018;#{len};#{timestr}"
  safe_write(socket, cmd, st)

  message = socket.recv(9000)
  fields  = message.split(";")
  if fields[2] != "0"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Time sync unsuccessful, please contact admin', '3')
  end
end

def SetTimezone(socket, st, db)
  string = "0088;0018;PST8PDT;"
  sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
       st.clientip, "Setting timezone: #{string}", '3')
  safe_write(socket, string, st)

  message = socket.recv(9000)
  fields  = message.split(";")
  if fields[2] != "0"
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Timezone setup unsuccessful, please contact admin', '3')
  end
end

def strip_header(msg)
  parts = msg.split(";")
  return nil if parts.length < 3
  parts[2..-1].join(";")
end

def transferDB(socket, st, db)
  res = sqlq(db, "SELECT ftp, failcount FROM HIDReaders WHERE mac = ?", st.readermac)
  rows = res&.to_a
  if rows.nil? || rows.empty?
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'Call for file transfer invalid, please contact admin', '1')
    return
  end

  row       = rows.first
  ftp       = row["ftp"].to_i
  failcount = row["failcount"].to_i

  if ftp == 1
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'FTP: File transfer in progress.', '3')
    ftpReader(socket, st, db)
  elsif failcount == 5
    sqlq(db, "INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
         st.clientip, 'File transfer failing, converting to FTP', '3')
    sqlq(db, "UPDATE HIDReaders SET ftp = '1' WHERE mac = ?", st.readermac)
    ftpReader(socket, st, db)
  else
    SendAccessDB(socket, st, db)
    SendIdentDB(socket, st, db)
  end
end

def recv_expect(socket, expected_code, st, db, context = "")
  loop do
    message = socket.recv(9000)
    fields  = message.split(";")
    code    = fields[0]

    case code
    when expected_code
      log("#{context}: <<< got expected #{expected_code}: #{message.inspect}")
      return message

    when "1080"
      # Heartbeat received mid-transfer — ack it and keep waiting.
      log("#{context}: <<< interleaved heartbeat 1080, acking and continuing")
      sqlq(db, "INSERT INTO HIDActive SET mac = ?, ip = ?, timestamp = NOW() " \
               "ON DUPLICATE KEY UPDATE mac = ?, ip = ?, timestamp = NOW()",
           st.readermac, st.clientip, st.readermac, st.clientip)
      st.socket_mutex.synchronize { socket.write("0080;0010;") }

    else
      log("#{context}: <<< unexpected code #{code.inspect} while waiting for #{expected_code}: #{message.inspect}")
      return nil
    end
  end
end

def safe_write(socket, data, st)
  st.socket_mutex.synchronize { socket.write(data) }
  rescue => e
    log("Socket write error: #{e.message}")
    st.shutdown = true
end

def log(message)
  Syslog.open($0, Syslog::LOG_PID | Syslog::LOG_CONS, Syslog::LOG_DAEMON) { |s| s.info message }
end

StdClass.new


######
##
## revision log
## v2.5.1 - Added send functions for AccessGroups, CfgFile, DoorGroups, EventMsg, InterfaceBoards,
##          InterfaceTypes, InternalID, Readers, eeprom.properties
## v2.5 - Adjusted to use 0060, or pull method on the readers instead of requiring them to send on read.
## v2.4 - Updated for use with ruby 2.5 and mysql2 gem
##
