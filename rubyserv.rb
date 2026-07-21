#       rubyserv.rb
#
#       Copyright 2026 Neil Sayers
#
#       rev 2.6.1
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

MAX_DB_RETRIES = 3
RECONNECT_ERRORS = [
  2006,   # MySQL server has gone away
  2013,   # Lost connection to MySQL server during query
  2055,   # Lost connection to MySQL server at '%s', system error: %d
].freeze

# Open a fresh DB connection with automatic retry on transient failures.
# Caller is responsible for closing it.
def db_connect(retries: MAX_DB_RETRIES)
  attempt = 0
  begin
    attempt += 1
    Mysql2::Client.new(
      DB_CONFIG.merge(
        reconnect:       false,
        connect_timeout: 10,
        read_timeout:    30,
        write_timeout:   30,
      )
    )
  rescue Mysql2::Error => e
    if attempt < retries
      log("DB connect failed (#{e.message}), retrying in 5s (#{retries - attempt} left)")
      sleep 5
      retry
    else
      log("DB connect failed after #{retries} attempts: #{e.message}")
      raise
    end
  end
end

# Open a connection, run one query, close immediately.
# Returns result rows as an array, empty array for no rows,
# or nil on error.
def db_query(sql, *params)
  client = db_connect
  stmt   = client.prepare(sql)
  result = stmt.execute(*params)
  result ? result.to_a : []
rescue Mysql2::Error => e
  log("DB error #{e.errno}: #{e.message}")
  nil
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

  cli_addr    = newsocket.peeraddr
  st.clientip = cli_addr[3]
  log("New connection from #{st.clientip}")
  $0 = "HIDSoft: Child #{st.clientip}"

  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
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
          db_query("INSERT INTO HIDActive SET mac = ?, ip = ?, timestamp = NOW() " \
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
            ParseCard(message, newsocket, st)
          end
          message = message[len..9000]
          fields  = message.split(";")

        # Log messages from the reader.
        when "1065", "1060", "1061"
          st.stack << "0067;0010;"
          clean = strip_header(message)
          if clean
            Thread.new do
              ParseMsg(clean, fields[0], st)
            end
          end
          flag = 0

        when "1062"
          st.awaiting_controller_data = false
          clean = strip_header(message)
          if clean && clean.length > 2
            Thread.new do
              ParseMsg(clean, fields[0], st)
            end
          end
          len     = fields[1].to_i
          message = message[len..9000]
          fields  = message.split(";")
          flag    = 0 if fields[0].nil? || fields[0].empty?

        # Reader confirms indexed files — tell it to make them active.
        when "1107"
          if fields[2] == "0"
            sleep 20
            db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                     st.clientip, 'LogMsg 1070: Reporting properly indexed files, reloading database files!', '3')
            st.stack << "0108;0010;"
          else
            db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                     st.clientip, 'LogMsg 1070: Reporting indexed files failed!', '1')
          end

        # DB changeover acknowledgement.
        when "1052"
          if fields[2] == "0"
            db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                     st.clientip, 'LogMsg 1052: DB Changeover completed', '3')
            db_query("UPDATE HIDReaders SET changeover = CURRENT_TIMESTAMP WHERE mac = ?", st.readermac)
            db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
          else
            db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                     st.clientip, "LogMsg 1052: DB Changeover failed with #{fields[2]}, restarting push", '1')
            db_query("UPDATE HIDReaders SET manual_open = '200' WHERE mac = ?", st.readermac)
          end
          flag = 0

        when nil, ""
          flag = 0

        else
          db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                   st.clientip, "Undefined Log message: #{message}", '3')
          log("Received: #{message}")
          flag = 0
        end

        # Flush one item from the stack to the socket.
        flush_stack(newsocket, st)
      end

    else
      # Socket not ready — idle tick.
      i += 1

      if st.readermac &&
         !st.awaiting_controller_data &&
         (Time.now - st.last_0060_request) >= 60

        st.stack << "0060;0010;"
        st.last_0060_request        = Time.now
        st.awaiting_controller_data = true
      end

      flush_stack(newsocket, st)

      if st.readermac && (i % 10 == 0)
        chkManualOverride(newsocket, st)
      end

      if st.readermac && i == 10
        ChkTimeSync(newsocket, st)
      end
    end

    sleep 0.25
  end

  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Detected lost connection from #{st.clientip}. Exiting.", '4')
  log("Detected lost connection from #{st.clientip}. Exiting.")
  newsocket.close
  exit!(0)
end

################################################
##
## Defined processes and steps
##

def checkActiveNeed(socket, st)
  res = db_query(
    "SELECT HIDActive.mac, " \
    "UNIX_TIMESTAMP(HIDActive.accessdb), " \
    "UNIX_TIMESTAMP(HIDActive.identdb), " \
    "UNIX_TIMESTAMP(HIDReaders.changeover) " \
    "FROM HIDActive " \
    "INNER JOIN HIDReaders ON HIDActive.mac = HIDReaders.mac " \
    "WHERE HIDActive.mac = ?",
    st.readermac)

  return if res.nil? || res.empty?

  row = res.first
  return unless row

  ten_minutes = 600
  two_hours   = 7200
  now         = Time.now.to_i

  if (row[3].to_i - row[1].to_i) > ten_minutes
    log("AccessDB is not within 10 minutes of Changeover")
    db_query("UPDATE HIDReaders SET manual_open = '240' WHERE mac = ?", st.readermac)
    return
  end

  if (row[3].to_i - row[2].to_i) > ten_minutes
    log("IdentDB is not within 10 minutes of Changeover")
    db_query("UPDATE HIDReaders SET manual_open = '250' WHERE mac = ?", st.readermac)
    return
  end

  if (now - row[3].to_i) > two_hours
    log("Time to update the reader")
    db_query("UPDATE HIDReaders SET manual_open = '200' WHERE mac = ?", st.readermac)
    return
  end

  db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
end

def chkManualOverride(socket, st)
  res = db_query("SELECT manual_open, cmd, ftp, failcount FROM HIDReaders WHERE mac = ?",
                 st.readermac)
  if res.nil? || res.empty?
    db_query("INSERT INTO HIDReaders (mac, groups, comment, manual_open, cmd) VALUES (?, '35', 'Reader-#{st.readermac}', '0', '100')",
             st.readermac)
    return
  end

  row         = res.first
  manual_open = row["manual_open"].to_i
  cmd         = row["cmd"].to_i
  ftp         = row["ftp"].to_i
  failcount   = row["failcount"].to_i

  # cmd-based tasks (separate from manual_open)
  case cmd
  when 52
    sleep 5
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: Database changeover command called', '3')
    SendDBChange(socket, st)
  when 100
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: New Reader setup called', '3')
    SetTime(socket, st)
    GetInternalID(socket, st)
    SendAccessGroups(socket, st)
    SendCfgFile(socket, st)
    SendDoorGroups(socket, st)
    Sendeeprom(socket, st)
    SendEventMsg(socket, st)
    SendHolidays(socket, st)
    SendInternalID(socket, st)
    SendInterfaceBoards(socket, st)
    SendInterfaceTypes(socket, st)
    SendIOLinker(socket, st)
    SendReaders(socket, st)
    SendSchedule(socket, st)
    SendAccessDB(socket, st)
    SendIdentDB(socket, st)
    SendDBChange(socket, st)
    db_query("UPDATE HIDReaders SET cmd = '0' WHERE mac = ?", st.readermac)
  end

  case manual_open
  when 1
    st.stack << "0094;0016;0;7;2;"
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'GRANT', 'Manual Admit')",
             st.readermac)
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 187
    log("Reader reboot requested")
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    st.stack << "0096;0013;32;"
    db_query("INSERT INTO HIDSoftLog (device, message) VALUES (?, 'Reader Reboot requested')",
             st.readermac)

  when 200
    st.stack << "0012;0013;99;"
    if ftp == 1 || failcount == 5
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, 'Task: AccessDB/IdentDB refresh called. FTP called', '3')
      db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
      transferDB(socket, st)
      db_query("UPDATE HIDReaders SET manual_open = '500' WHERE mac = ?", st.readermac)
    else
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, 'Task: AccessDB/IdentDB refresh called. HID linker called', '3')
      db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
      SendIdentDB(socket, st)
      SendAccessDB(socket, st)
      sleep 5
      db_query("UPDATE HIDReaders SET manual_open = '500' WHERE mac = ?", st.readermac)
    end

  when 240
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: AccessDB refresh only called', '3')
    SendAccessDB(socket, st)
    st.stack << "0012;0012;9;"
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 250
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: IdentDB refresh only called', '3')
    SendIdentDB(socket, st)
    st.stack << "0012;0012;9;"
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 300
    system("/usr/local/sbin/HIDSoft/bin/buildsch.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildiol.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildho.pl", st.readermac)
    sleep 1
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: Schedule/IOLinker/Holiday refresh called', '3')
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    SendSchedule(socket, st)
    sleep 1
    SendHolidays(socket, st)
    sleep 1
    SendIOLinker(socket, st)
    st.stack << "0012;0012;5;"

  when 500
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: Database changeover command called', '3')
    SendDBChange(socket, st)

  when 501
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: IOLinker Reset', '3')
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    st.stack << "0012;0012;5;"

  when 666
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: Reader reboot request', '3')
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    st.stack << "0012;0013;99;"

  when 900
    log("Calling InternalID grab")
    GetInternalID(socket, st)
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 999
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: Full Configuration called', '3')
    system("/usr/local/sbin/HIDSoft/bin/builddb.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildsch.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildho.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildiol.pl", st.readermac)
    SendAccessDB(socket, st)
    sleep 1
    SendIdentDB(socket, st)
    sleep 1
    SendDBChange(socket, st)
    sleep 1
    SendSchedule(socket, st)
    SendHolidays(socket, st)
    sleep 1
    st.stack << "0012;0013;99;"
  end
end

def ChkTimeSync(socket, st)
  res = db_query("SELECT UNIX_TIMESTAMP(lasttimesync) as ts FROM HIDReaders WHERE mac = ?",
                 st.readermac)
  return if res.nil? || res.empty?

  row = res.first
  return unless row

  db_time   = row["ts"].to_i
  threshold = Time.now.to_i - 600   # 10 minutes

  if threshold > db_time
    SetTime(socket, st)
    db_query("UPDATE HIDReaders SET lasttimesync = NOW() WHERE mac = ?", st.readermac)
  end
end

def flush_stack(socket, st)
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

def ftpReader(socket, st)
  timeinsert = Time.new.strftime("%Y-%m-%d %k:%M:%S")
  system("/usr/local/sbin/HIDSoft/bin/deployftp.sh", st.readermac)
  db_query("UPDATE HIDReaders SET lasttimesync = ? WHERE mac = ?", timeinsert, st.readermac)
end

def GetInternalID(socket, st)
  path = "/mnt/flash/TaskConfig/InternalID"
  cmd  = "0033;#{pad4(path.length + 10)};#{path};"
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
    chunk = message[(second + 1)..-1] || ""
    log("InternalID: code=#{code} len=#{len} chunk.bytes=#{chunk.bytesize}")

    case code
    when "1033"   # GET_FILE_MORE
      data << chunk
      log("InternalID: accumulated #{data.bytesize} bytes")
      safe_write(socket, "0034;0010;", st)

    when "1034"   # GET_FILE_END
      data << chunk
      log("InternalID raw:\n#{data}")
      filename = "/usr/local/sbin/HIDSoft/bin/InternalID-#{st.readermac}"
      File.write(filename, data)
      log("InternalID: saved to #{filename}")
      return data.gsub(/^INTID=.*$/, "INTID=1")

    when "1080"   # heartbeat
      safe_write(socket, "0080;0010;", st)

    else
      log("InternalID: unexpected response #{message.inspect}")
      return nil
    end
  end
end

def newReaderSetup(socket, st)
  SetTimezone(socket, st)
  SetTime(socket, st)

  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, 'New Reader setup called', '3')
  safe_write(socket, "0030;0040;/mnt/flash/TaskConfig/Readers;", st)

  message = recv_expect(socket, "1030", st, "Readers VERTX_SEND_FILE")
  unless message
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Readers: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("Readers: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "9980"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Readers: Error, xfer in progress.', '2')
    sleep 5
    safe_write(socket, "0030;0040;/mnt/flash/TaskConfig/Readers;", st)
  end

  if fields[0] == "1030"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Reader: Got OK, sending default reader settings', '3')
    safe_write(socket,
               "0032;0148;# Readers configuration file\n" \
               "#r IID IF a AM psup pincmd rdrtyp elev apbtyp tmout apbact entryid exitid lkup\n" \
               "1 1 0 0 2 0 0 1 0 0 0 0 0 0 1\n",
               st)
  end

  message = recv_expect(socket, "1030", st, "Readers final chunk")
  unless message
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Readers: unexpected response to final chunk, aborting', '1')
    return
  end

  fields = message.split(";")
  if fields[0] == "1030"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Readers: File sent successfully!', '3')
  else
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Readers: Error, xfer failed. Please check with admin', '1')
  end

  st.stack << "0012;0013;99;"
end

def pad4(n)
  n.to_s.rjust(4, '0')
end

def ParseCard(msg, socket, st)
  fields   = msg.split(";")
  card_num = fields[13]
  mac      = fields[10]

  safe_write(socket, "0094;0016;0;9;0;", st)

  res = db_query("SELECT groupid, id FROM HIDCards " \
                 "WHERE cardnum = ? " \
                 "AND (expires IS NULL OR expires > NOW()) " \
                 "AND (deleted IS NULL OR deleted > NOW()) " \
                 "ORDER BY lastupdate DESC",
                 card_num)

  if res.nil? || res.empty?
    log("No card record found.")
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-UNKWN', ?)",
             st.readermac, card_num)
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "Card #{card_num} unknown, please check card assignment", '3')
    safe_write(socket, "0094;0016;0;8;2;", st)
    return
  end

  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Card record found, checking permissions for #{card_num}", '4')
  card_row = res.first

  reader_res = db_query("SELECT groups FROM HIDReaders WHERE mac = ?", mac)

  if reader_res.nil? || reader_res.empty?
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Reader permission issue, please contact an Admin', '1')
    return
  end

  groups = reader_res.first["groups"].to_s.split(",")

  if groups.include?(card_row["groupid"].to_s)
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'GRANT', ?)",
             st.readermac, card_num)
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "Card #{card_num} granted", '2')
    safe_write(socket, "0094;0016;0;7;2;", st)
  else
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-NOACC', ?)",
             st.readermac, card_num)
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "Card #{card_num} denied, no access rights for door #{st.clientip}", '3')
    safe_write(socket, "0094;0016;0;8;2;", st)
  end
end

def parseCheckCard(msg, socket, st)
  fields = msg.split(";")
  safe_write(socket, "0094;0016;0;9;0;", st)

  res = db_query("SELECT groupid, contact_id, id FROM HIDCards " \
                 "WHERE cardnum = ? AND (expires IS NULL OR expires > NOW())",
                 fields[2])
  return unless res

  if res.empty?
    log("No card record found.")
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-UNKWN', ?)",
             st.readermac, fields[2])
    safe_write(socket, "0094;0016;0;8;2;", st)
    return
  end

  reader_res = db_query("SELECT groups FROM HIDReaders WHERE mac = ?", st.readermac)
  return unless reader_res
  return if reader_res.empty?

  card_row = res.first
  groups   = reader_res.first["groups"].to_s.split(",")

  if groups.include?(card_row["groupid"].to_s)
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'GRANT', ?)",
             st.readermac, fields[2])
    log("Granting access to #{fields[2]}")
    safe_write(socket, "0094;0016;0;7;2;", st)
  else
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-NOACC', ?)",
             st.readermac, fields[2])
    log("Deny access to #{fields[2]}")
    safe_write(socket, "0094;0016;0;8;2;", st)
  end
end

def ParseMsg(msg, event_type, st)
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
      log("X1: #{info9}")       if info9
      log("X2: #{info10}")      if info10
      log("X3: #{fields[11]}") if fields[11]
      log("X4: #{fields[12]}") if fields[12]
      log("X5: #{info13}")      if info13
    end

    time_field = fields.find { |f| f =~ /\d{2}:\d{2}:\d{2}/ }
    date_field = fields.find { |f| f =~ /\d{2}\/\d{2}\/\d{4}/ }

    if time_field && date_field
      time_val  = time_field[/\d{2}:\d{2}:\d{2}/]
      date_val  = date_field[/\d{2}\/\d{2}\/\d{4}/]
      parts     = date_val.split("/")
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
          db_query("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES (?, ?, ?, ?)",
                   st.readermac, task_code, info11, timestamp)
        elsif info3 == "4"
          if info9 == "901"
            if info10 == "1"
              db_query("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES (?, 'ALARM', 'DOOR HAS BEEN FORCED', ?)",
                       st.readermac, timestamp)
              db_query("UPDATE HIDAlarm SET alarm = '1' WHERE id = '1'")
              st.stack << "0094;0017;0;11;0;"
            elsif info10 == "0"
              st.stack << "0094;0017;0;11;1;"
            end
          elsif info9 == "903"
            if info10 == "1"
              db_query("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES (?, 'HELD', 'DOOR HAS BEEN HELD', ?)",
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

# ─────────────────────────────────────────────────────────────────────────────
# Generic file-send helper used by all Send* functions.
# Handles: VERTX_SEND_FILE → chunked VERTX_SEND_DATA_CONTINUE → VERTX_SEND_DATA_END
# ─────────────────────────────────────────────────────────────────────────────
def send_file_to_reader(socket, st, remote_path, local_path, label)
  data = File.binread(local_path)
  log("#{label} file=#{local_path} size=#{data.bytesize} encoding=#{data.encoding}")

  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "#{label}: Initiate xfer", '3')

  path_len = pad4(remote_path.length + 10)
  cmd      = "0030;#{path_len};#{remote_path};"
  log("#{label}: >>> VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, "#{label} VERTX_SEND_FILE")
  unless message
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "#{label}: unexpected response to VERTX_SEND_FILE, aborting", '1')
    return
  end

  fields = message.split(";")

  if fields[0] == "9980"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "#{label}: xfer already in progress, retrying", '3')
    sleep 5
    safe_write(socket, cmd, st)
    message = recv_expect(socket, "1030", st, "#{label} RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "#{label}: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk       = data.slice!(0, 4084)
    newsize     = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("#{label}: >>> chunk #{chunk_count} CONTINUE 0031;#{newsize}; remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, "#{label} chunk #{chunk_count}")
    unless message
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, "#{label}: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    fields = message.split(";")
    unless fields[0] == "1030"
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, "#{label}: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("#{label}: >>> final chunk #{chunk_count} END 0032;#{len}; bytes=#{data.bytesize} total=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, "#{label} VERTX_SEND_DATA_END")
  fields  = message ? message.split(";") : []

  if fields[0] == "1030"
    log("#{label}: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "#{label}: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("#{label}: transfer failed. final response=#{message.inspect}")
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "#{label}: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
rescue IOError, Errno::ECONNRESET => e
  log("#{label}: connection lost: #{e.message}")
  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "#{label}: Connection lost during transfer: #{e.message}", '1')
end

def SendAccessDB(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/NewAccessDB-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/NOC-AccessDB"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/NewAccessDB",
                      File.exist?(path) ? path : fallback,
                      "AccessDB")
end

def SendAccessGroups(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/AccessGroups-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/AccessGroups"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/AccessGroups",
                      File.exist?(path) ? path : fallback,
                      "AccessGroups")
end

def SendCfgFile(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/CfgFile-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/CfgFile"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/CfgFile",
                      File.exist?(path) ? path : fallback,
                      "CfgFile")
end

def SendDBChange(socket, st)
  db_query("UPDATE HIDReaders SET cmd = '0' WHERE mac = ?", st.readermac)
  safe_write(socket, "0052;0015;2000;", st)

  message = recv_expect(socket, "1052", st, "SendDBChange")
  return unless message
  log("Message: #{message}")
  fields = message.split(";")

  if fields[0] == "1052"
    if fields[2] == "0"
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, 'LogMsg 1052: DB Changeover completed', '3')
      db_query("UPDATE HIDReaders SET changeover = CURRENT_TIMESTAMP WHERE mac = ?", st.readermac)
    else
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, "LogMsg 1052: DB Changeover failed with #{fields[2]}, manual review required", '1')
      db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    end
  end
end

def SendDoorGroups(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/DoorGroups-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/DoorGroups"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/DoorGroups",
                      File.exist?(path) ? path : fallback,
                      "DoorGroups")
end

def Sendeeprom(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/eeprom.properties-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/eeprom.properties"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/eeprom.properties",
                      File.exist?(path) ? path : fallback,
                      "eeprom")
end

def SendEventMsg(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/EventMsg-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/EventMsg"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/EventMsg",
                      File.exist?(path) ? path : fallback,
                      "EventMsg")
end

def SendHolidays(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/Holidays-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/Holidays"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/Holidays",
                      File.exist?(path) ? path : fallback,
                      "Holidays")
end

def SendIdentDB(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/NewIdentDB-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/NOC-IdentDB"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/NewIdentDB",
                      File.exist?(path) ? path : fallback,
                      "IdentDB")
end

def SendInternalID(socket, st)
  path = "/usr/local/sbin/HIDSoft/bin/InternalID-#{st.readermac}"
  unless File.exist?(path)
    log("InternalID: cache miss for #{st.readermac}, pulling from controller")
    result = GetInternalID(socket, st)
    unless result
      log("InternalID: controller fetch failed for #{st.readermac}")
      return
    end
  end
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/InternalID",
                      path,
                      "InternalID")
end

def SendInterfaceBoards(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/InterfaceBoards-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/InterfaceBoards"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/InterfaceBoards",
                      File.exist?(path) ? path : fallback,
                      "InterfaceBoards")
end

def SendInterfaceTypes(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/InterfaceTypes-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/InterfaceTypes"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/InterfaceTypes",
                      File.exist?(path) ? path : fallback,
                      "InterfaceTypes")
end

def SendIOLinker(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/IOLinkerRules-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/IOLinkerRules"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/IOLinkerRules",
                      File.exist?(path) ? path : fallback,
                      "IOLinkerRules")
end

def SendReaders(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/Readers-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/Readers"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/Readers",
                      File.exist?(path) ? path : fallback,
                      "Readers")
end

def SendSchedule(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/Schedules-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/Schedules"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/Schedules",
                      File.exist?(path) ? path : fallback,
                      "Schedules")
end

def SetTime(socket, st)
  timestr = Time.new.strftime("%m;%d;%Y;%H;%M;%S;")
  len     = pad4(timestr.length + 10)
  cmd     = "0018;#{len};#{timestr}"
  safe_write(socket, cmd, st)

  message = socket.recv(9000)
  fields  = message.split(";")
  if fields[2] != "0"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Time sync unsuccessful, please contact admin', '3')
  end
end

def SetTimezone(socket, st)
  string = "0088;0018;PST8PDT;"
  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Setting timezone: #{string}", '3')
  safe_write(socket, string, st)

  message = socket.recv(9000)
  fields  = message.split(";")
  if fields[2] != "0"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Timezone setup unsuccessful, please contact admin', '3')
  end
end

def strip_header(msg)
  parts = msg.split(";")
  return nil if parts.length < 3
  parts[2..-1].join(";")
end

def transferDB(socket, st)
  res = db_query("SELECT ftp, failcount FROM HIDReaders WHERE mac = ?", st.readermac)
  if res.nil? || res.empty?
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Call for file transfer invalid, please contact admin', '1')
    return
  end

  row       = res.first
  ftp       = row["ftp"].to_i
  failcount = row["failcount"].to_i

  if ftp == 1
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'FTP: File transfer in progress.', '3')
    ftpReader(socket, st)
  elsif failcount == 5
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'File transfer failing, converting to FTP', '3')
    db_query("UPDATE HIDReaders SET ftp = '1' WHERE mac = ?", st.readermac)
    ftpReader(socket, st)
  else
    SendAccessDB(socket, st)
    SendIdentDB(socket, st)
  end
end

def recv_expect(socket, expected_code, st, context = "")
  loop do
    message = socket.recv(9000)
    fields  = message.split(";")
    code    = fields[0]

    case code
    when expected_code
      log("#{context}: <<< got expected #{expected_code}: #{message.inspect}")
      return message

    when "1080"
      log("#{context}: <<< interleaved heartbeat")
      db_query(
        "INSERT INTO HIDActive SET mac=?, ip=?, timestamp=NOW() " \
        "ON DUPLICATE KEY UPDATE mac=?, ip=?, timestamp=NOW()",
        st.readermac, st.clientip,
        st.readermac, st.clientip
      )
      safe_write(socket, "0080;0010;", st)
      next

    when "9980"
      log("#{context}: <<< controller busy: #{message.inspect}")
      return message

    else
      log("#{context}: <<< unexpected #{message.inspect}")
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
## v2.6.1 - Fixed closing of the ChildProcess fork, was not killing processess that disappeared 
##          from the server.  Patched the recv_expect() to fix the 9980 fault blocking transfer.
## v2.6.0 - Replaced persistent DbHandle pattern with per-query open/close via db_query().
##          No DB connection is held open between queries anywhere in the process.
##          Removed DbHandle struct entirely. Removed db parameter from all method signatures.
##          Removed thread_db locals and their ensure/close blocks from Thread.new spawns.
##          Set reconnect: false in db_connect since each connection is used once and closed.
##          Removed ensure db&.close from ChildProc (no persistent handle to close).
## v2.5.2 - Full DbHandle migration: all sqlq() calls replaced with db.query(),
##          all threads use their own DbHandle, ensure closes db correctly.
##          Extracted send_file_to_reader() helper to eliminate Send* duplication.
## v2.5.1 - Added send functions for AccessGroups, CfgFile, DoorGroups, EventMsg, InterfaceBoards,
##          InterfaceTypes, InternalID, Readers, eeprom.properties
## v2.5 - Adjusted to use 0060, or pull method on the readers instead of requiring them to send on read.
## v2.4 - Updated for use with ruby 2.5 and mysql2 gem#       rubyserv.rb
#
#       Copyright 2026 Neil Sayers
#
#       rev 2.6.0
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

MAX_DB_RETRIES = 3
RECONNECT_ERRORS = [
  2006,   # MySQL server has gone away
  2013,   # Lost connection to MySQL server during query
  2055,   # Lost connection to MySQL server at '%s', system error: %d
].freeze

# Open a fresh DB connection with automatic retry on transient failures.
# Caller is responsible for closing it.
def db_connect(retries: MAX_DB_RETRIES)
  attempt = 0
  begin
    attempt += 1
    Mysql2::Client.new(
      DB_CONFIG.merge(
        reconnect:       false,
        connect_timeout: 10,
        read_timeout:    30,
        write_timeout:   30,
      )
    )
  rescue Mysql2::Error => e
    if attempt < retries
      log("DB connect failed (#{e.message}), retrying in 5s (#{retries - attempt} left)")
      sleep 5
      retry
    else
      log("DB connect failed after #{retries} attempts: #{e.message}")
      raise
    end
  end
end

# Open a connection, run one query, close immediately.
# Returns result rows as an array, empty array for no rows,
# or nil on error.
def db_query(sql, *params)
  client = db_connect
  stmt   = client.prepare(sql)
  result = stmt.execute(*params)
  result ? result.to_a : []
rescue Mysql2::Error => e
  log("DB error #{e.errno}: #{e.message}")
  nil
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

  cli_addr    = newsocket.peeraddr
  st.clientip = cli_addr[3]
  log("New connection from #{st.clientip}")
  $0 = "HIDSoft: Child #{st.clientip}"

  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
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
          db_query("INSERT INTO HIDActive SET mac = ?, ip = ?, timestamp = NOW() " \
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
            ParseCard(message, newsocket, st)
          end
          message = message[len..9000]
          fields  = message.split(";")

        # Log messages from the reader.
        when "1065", "1060", "1061"
          st.stack << "0067;0010;"
          clean = strip_header(message)
          if clean
            Thread.new do
              ParseMsg(clean, fields[0], st)
            end
          end
          flag = 0

        when "1062"
          st.awaiting_controller_data = false
          clean = strip_header(message)
          if clean && clean.length > 2
            Thread.new do
              ParseMsg(clean, fields[0], st)
            end
          end
          len     = fields[1].to_i
          message = message[len..9000]
          fields  = message.split(";")
          flag    = 0 if fields[0].nil? || fields[0].empty?

        # Reader confirms indexed files — tell it to make them active.
        when "1107"
          if fields[2] == "0"
            sleep 20
            db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                     st.clientip, 'LogMsg 1070: Reporting properly indexed files, reloading database files!', '3')
            st.stack << "0108;0010;"
          else
            db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                     st.clientip, 'LogMsg 1070: Reporting indexed files failed!', '1')
          end

        # DB changeover acknowledgement.
        when "1052"
          if fields[2] == "0"
            db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                     st.clientip, 'LogMsg 1052: DB Changeover completed', '3')
            db_query("UPDATE HIDReaders SET changeover = CURRENT_TIMESTAMP WHERE mac = ?", st.readermac)
            db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
          else
            db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                     st.clientip, "LogMsg 1052: DB Changeover failed with #{fields[2]}, restarting push", '1')
            db_query("UPDATE HIDReaders SET manual_open = '200' WHERE mac = ?", st.readermac)
          end
          flag = 0

        when nil, ""
          flag = 0

        else
          db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
                   st.clientip, "Undefined Log message: #{message}", '3')
          log("Received: #{message}")
          flag = 0
        end

        # Flush one item from the stack to the socket.
        flush_stack(newsocket, st)
      end

    else
      # Socket not ready — idle tick.
      i += 1

      if st.readermac &&
         !st.awaiting_controller_data &&
         (Time.now - st.last_0060_request) >= 60

        st.stack << "0060;0010;"
        st.last_0060_request        = Time.now
        st.awaiting_controller_data = true
      end

      flush_stack(newsocket, st)

      if st.readermac && (i % 10 == 0)
        chkManualOverride(newsocket, st)
      end

      if st.readermac && i == 10
        ChkTimeSync(newsocket, st)
      end
    end

    sleep 0.25
  end

  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Detected lost connection from #{st.clientip}. Exiting.", '4')
  log("Detected lost connection from #{st.clientip}. Exiting.")
  newsocket.close
end

################################################
##
## Defined processes and steps
##

def checkActiveNeed(socket, st)
  res = db_query(
    "SELECT HIDActive.mac, " \
    "UNIX_TIMESTAMP(HIDActive.accessdb), " \
    "UNIX_TIMESTAMP(HIDActive.identdb), " \
    "UNIX_TIMESTAMP(HIDReaders.changeover) " \
    "FROM HIDActive " \
    "INNER JOIN HIDReaders ON HIDActive.mac = HIDReaders.mac " \
    "WHERE HIDActive.mac = ?",
    st.readermac)

  return if res.nil? || res.empty?

  row = res.first
  return unless row

  ten_minutes = 600
  two_hours   = 7200
  now         = Time.now.to_i

  if (row[3].to_i - row[1].to_i) > ten_minutes
    log("AccessDB is not within 10 minutes of Changeover")
    db_query("UPDATE HIDReaders SET manual_open = '240' WHERE mac = ?", st.readermac)
    return
  end

  if (row[3].to_i - row[2].to_i) > ten_minutes
    log("IdentDB is not within 10 minutes of Changeover")
    db_query("UPDATE HIDReaders SET manual_open = '250' WHERE mac = ?", st.readermac)
    return
  end

  if (now - row[3].to_i) > two_hours
    log("Time to update the reader")
    db_query("UPDATE HIDReaders SET manual_open = '200' WHERE mac = ?", st.readermac)
    return
  end

  db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
end

def chkManualOverride(socket, st)
  res = db_query("SELECT manual_open, cmd, ftp, failcount FROM HIDReaders WHERE mac = ?",
                 st.readermac)
  if res.nil? || res.empty?
    db_query("INSERT INTO HIDReaders (mac, groups, comment, manual_open, cmd) VALUES (?, '35', 'Reader-#{st.readermac}', '0', '100')",
             st.readermac)
    return
  end

  row         = res.first
  manual_open = row["manual_open"].to_i
  cmd         = row["cmd"].to_i
  ftp         = row["ftp"].to_i
  failcount   = row["failcount"].to_i

  # cmd-based tasks (separate from manual_open)
  case cmd
  when 52
    sleep 5
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: Database changeover command called', '3')
    SendDBChange(socket, st)
  when 100
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: New Reader setup called', '3')
    SetTime(socket, st)
    GetInternalID(socket, st)
    SendAccessGroups(socket, st)
    SendCfgFile(socket, st)
    SendDoorGroups(socket, st)
    Sendeeprom(socket, st)
    SendEventMsg(socket, st)
    SendHolidays(socket, st)
    SendInternalID(socket, st)
    SendInterfaceBoards(socket, st)
    SendInterfaceTypes(socket, st)
    SendIOLinker(socket, st)
    SendReaders(socket, st)
    SendSchedule(socket, st)
    SendAccessDB(socket, st)
    SendIdentDB(socket, st)
    SendDBChange(socket, st)
    db_query("UPDATE HIDReaders SET cmd = '0' WHERE mac = ?", st.readermac)
  end

  case manual_open
  when 1
    st.stack << "0094;0016;0;7;2;"
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'GRANT', 'Manual Admit')",
             st.readermac)
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 187
    log("Reader reboot requested")
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    st.stack << "0096;0013;32;"
    db_query("INSERT INTO HIDSoftLog (device, message) VALUES (?, 'Reader Reboot requested')",
             st.readermac)

  when 200
    st.stack << "0012;0013;99;"
    if ftp == 1 || failcount == 5
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, 'Task: AccessDB/IdentDB refresh called. FTP called', '3')
      db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
      transferDB(socket, st)
      db_query("UPDATE HIDReaders SET manual_open = '500' WHERE mac = ?", st.readermac)
    else
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, 'Task: AccessDB/IdentDB refresh called. HID linker called', '3')
      db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
      SendIdentDB(socket, st)
      SendAccessDB(socket, st)
      sleep 5
      db_query("UPDATE HIDReaders SET manual_open = '500' WHERE mac = ?", st.readermac)
    end

  when 240
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: AccessDB refresh only called', '3')
    SendAccessDB(socket, st)
    st.stack << "0012;0012;9;"
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 250
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: IdentDB refresh only called', '3')
    SendIdentDB(socket, st)
    st.stack << "0012;0012;9;"
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 300
    system("/usr/local/sbin/HIDSoft/bin/buildsch.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildiol.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildho.pl", st.readermac)
    sleep 1
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: Schedule/IOLinker/Holiday refresh called', '3')
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    SendSchedule(socket, st)
    sleep 1
    SendHolidays(socket, st)
    sleep 1
    SendIOLinker(socket, st)
    st.stack << "0012;0012;5;"

  when 500
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: Database changeover command called', '3')
    SendDBChange(socket, st)

  when 501
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: IOLinker Reset', '3')
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    st.stack << "0012;0012;5;"

  when 666
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: Reader reboot request', '3')
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    st.stack << "0012;0013;99;"

  when 900
    log("Calling InternalID grab")
    GetInternalID(socket, st)
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)

  when 999
    db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Task: Full Configuration called', '3')
    system("/usr/local/sbin/HIDSoft/bin/builddb.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildsch.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildho.pl", st.readermac)
    sleep 1
    system("/usr/local/sbin/HIDSoft/bin/buildiol.pl", st.readermac)
    SendAccessDB(socket, st)
    sleep 1
    SendIdentDB(socket, st)
    sleep 1
    SendDBChange(socket, st)
    sleep 1
    SendSchedule(socket, st)
    SendHolidays(socket, st)
    sleep 1
    st.stack << "0012;0013;99;"
  end
end

def ChkTimeSync(socket, st)
  res = db_query("SELECT UNIX_TIMESTAMP(lasttimesync) as ts FROM HIDReaders WHERE mac = ?",
                 st.readermac)
  return if res.nil? || res.empty?

  row = res.first
  return unless row

  db_time   = row["ts"].to_i
  threshold = Time.now.to_i - 600   # 10 minutes

  if threshold > db_time
    SetTime(socket, st)
    db_query("UPDATE HIDReaders SET lasttimesync = NOW() WHERE mac = ?", st.readermac)
  end
end

def flush_stack(socket, st)
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

def ftpReader(socket, st)
  timeinsert = Time.new.strftime("%Y-%m-%d %k:%M:%S")
  system("/usr/local/sbin/HIDSoft/bin/deployftp.sh", st.readermac)
  db_query("UPDATE HIDReaders SET lasttimesync = ? WHERE mac = ?", timeinsert, st.readermac)
end

def GetInternalID(socket, st)
  path = "/mnt/flash/TaskConfig/InternalID"
  cmd  = "0033;#{pad4(path.length + 10)};#{path};"
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
    chunk = message[(second + 1)..-1] || ""
    log("InternalID: code=#{code} len=#{len} chunk.bytes=#{chunk.bytesize}")

    case code
    when "1033"   # GET_FILE_MORE
      data << chunk
      log("InternalID: accumulated #{data.bytesize} bytes")
      safe_write(socket, "0034;0010;", st)

    when "1034"   # GET_FILE_END
      data << chunk
      log("InternalID raw:\n#{data}")
      filename = "/usr/local/sbin/HIDSoft/bin/InternalID-#{st.readermac}"
      File.write(filename, data)
      log("InternalID: saved to #{filename}")
      return data.gsub(/^INTID=.*$/, "INTID=1")

    when "1080"   # heartbeat
      safe_write(socket, "0080;0010;", st)

    else
      log("InternalID: unexpected response #{message.inspect}")
      return nil
    end
  end
end

def newReaderSetup(socket, st)
  SetTimezone(socket, st)
  SetTime(socket, st)

  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, 'New Reader setup called', '3')
  safe_write(socket, "0030;0040;/mnt/flash/TaskConfig/Readers;", st)

  message = recv_expect(socket, "1030", st, "Readers VERTX_SEND_FILE")
  unless message
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Readers: unexpected response to VERTX_SEND_FILE, aborting', '1')
    return
  end

  log("Readers: <<< response to VERTX_SEND_FILE: #{message.inspect} fields=#{message.split(';').inspect}")
  fields = message.split(";")

  if fields[0] == "9980"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Readers: Error, xfer in progress.', '2')
    sleep 5
    safe_write(socket, "0030;0040;/mnt/flash/TaskConfig/Readers;", st)
  end

  if fields[0] == "1030"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Reader: Got OK, sending default reader settings', '3')
    safe_write(socket,
               "0032;0148;# Readers configuration file\n" \
               "#r IID IF a AM psup pincmd rdrtyp elev apbtyp tmout apbact entryid exitid lkup\n" \
               "1 1 0 0 2 0 0 1 0 0 0 0 0 0 1\n",
               st)
  end

  message = recv_expect(socket, "1030", st, "Readers final chunk")
  unless message
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Readers: unexpected response to final chunk, aborting', '1')
    return
  end

  fields = message.split(";")
  if fields[0] == "1030"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Readers: File sent successfully!', '3')
  else
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Readers: Error, xfer failed. Please check with admin', '1')
  end

  st.stack << "0012;0013;99;"
end

def pad4(n)
  n.to_s.rjust(4, '0')
end

def ParseCard(msg, socket, st)
  fields   = msg.split(";")
  card_num = fields[13]
  mac      = fields[10]

  safe_write(socket, "0094;0016;0;9;0;", st)

  res = db_query("SELECT groupid, id FROM HIDCards " \
                 "WHERE cardnum = ? " \
                 "AND (expires IS NULL OR expires > NOW()) " \
                 "AND (deleted IS NULL OR deleted > NOW()) " \
                 "ORDER BY lastupdate DESC",
                 card_num)

  if res.nil? || res.empty?
    log("No card record found.")
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-UNKWN', ?)",
             st.readermac, card_num)
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "Card #{card_num} unknown, please check card assignment", '3')
    safe_write(socket, "0094;0016;0;8;2;", st)
    return
  end

  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Card record found, checking permissions for #{card_num}", '4')
  card_row = res.first

  reader_res = db_query("SELECT groups FROM HIDReaders WHERE mac = ?", mac)

  if reader_res.nil? || reader_res.empty?
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Reader permission issue, please contact an Admin', '1')
    return
  end

  groups = reader_res.first["groups"].to_s.split(",")

  if groups.include?(card_row["groupid"].to_s)
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'GRANT', ?)",
             st.readermac, card_num)
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "Card #{card_num} granted", '2')
    safe_write(socket, "0094;0016;0;7;2;", st)
  else
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-NOACC', ?)",
             st.readermac, card_num)
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "Card #{card_num} denied, no access rights for door #{st.clientip}", '3')
    safe_write(socket, "0094;0016;0;8;2;", st)
  end
end

def parseCheckCard(msg, socket, st)
  fields = msg.split(";")
  safe_write(socket, "0094;0016;0;9;0;", st)

  res = db_query("SELECT groupid, contact_id, id FROM HIDCards " \
                 "WHERE cardnum = ? AND (expires IS NULL OR expires > NOW())",
                 fields[2])
  return unless res

  if res.empty?
    log("No card record found.")
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-UNKWN', ?)",
             st.readermac, fields[2])
    safe_write(socket, "0094;0016;0;8;2;", st)
    return
  end

  reader_res = db_query("SELECT groups FROM HIDReaders WHERE mac = ?", st.readermac)
  return unless reader_res
  return if reader_res.empty?

  card_row = res.first
  groups   = reader_res.first["groups"].to_s.split(",")

  if groups.include?(card_row["groupid"].to_s)
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'GRANT', ?)",
             st.readermac, fields[2])
    log("Granting access to #{fields[2]}")
    safe_write(socket, "0094;0016;0;7;2;", st)
  else
    db_query("INSERT INTO HIDLog (reader, taskcode, message) VALUES (?, 'DENY-NOACC', ?)",
             st.readermac, fields[2])
    log("Deny access to #{fields[2]}")
    safe_write(socket, "0094;0016;0;8;2;", st)
  end
end

def ParseMsg(msg, event_type, st)
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
      log("X1: #{info9}")       if info9
      log("X2: #{info10}")      if info10
      log("X3: #{fields[11]}") if fields[11]
      log("X4: #{fields[12]}") if fields[12]
      log("X5: #{info13}")      if info13
    end

    time_field = fields.find { |f| f =~ /\d{2}:\d{2}:\d{2}/ }
    date_field = fields.find { |f| f =~ /\d{2}\/\d{2}\/\d{4}/ }

    if time_field && date_field
      time_val  = time_field[/\d{2}:\d{2}:\d{2}/]
      date_val  = date_field[/\d{2}\/\d{2}\/\d{4}/]
      parts     = date_val.split("/")
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
          db_query("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES (?, ?, ?, ?)",
                   st.readermac, task_code, info11, timestamp)
        elsif info3 == "4"
          if info9 == "901"
            if info10 == "1"
              db_query("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES (?, 'ALARM', 'DOOR HAS BEEN FORCED', ?)",
                       st.readermac, timestamp)
              db_query("UPDATE HIDAlarm SET alarm = '1' WHERE id = '1'")
              st.stack << "0094;0017;0;11;0;"
            elsif info10 == "0"
              st.stack << "0094;0017;0;11;1;"
            end
          elsif info9 == "903"
            if info10 == "1"
              db_query("INSERT INTO HIDLog (reader, taskcode, message, timestamp) VALUES (?, 'HELD', 'DOOR HAS BEEN HELD', ?)",
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

# ─────────────────────────────────────────────────────────────────────────────
# Generic file-send helper used by all Send* functions.
# Handles: VERTX_SEND_FILE → chunked VERTX_SEND_DATA_CONTINUE → VERTX_SEND_DATA_END
# ─────────────────────────────────────────────────────────────────────────────
def send_file_to_reader(socket, st, remote_path, local_path, label)
  data = File.read(local_path)
  log("#{label} file=#{local_path} size=#{data.bytesize} encoding=#{data.encoding}")

  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "#{label}: Initiate xfer", '3')

  path_len = pad4(remote_path.length + 10)
  cmd      = "0030;#{path_len};#{remote_path};"
  log("#{label}: >>> VERTX_SEND_FILE: #{cmd}")
  safe_write(socket, cmd, st)

  message = recv_expect(socket, "1030", st, "#{label} VERTX_SEND_FILE")
  unless message
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "#{label}: unexpected response to VERTX_SEND_FILE, aborting", '1')
    return
  end

  fields = message.split(";")

  if fields[0] == "9980"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "#{label}: xfer already in progress, retrying", '3')
    sleep 5
    safe_write(socket, cmd, st)
    message = recv_expect(socket, "1030", st, "#{label} RETRY")
    return unless message
    fields = message.split(";")
  end

  unless fields[0] == "1030"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "#{label}: unexpected response #{fields[0].inspect} to VERTX_SEND_FILE, aborting", '1')
    return
  end

  chunk_count = 0
  total_bytes = 0

  while data.size > 4084
    chunk       = data.slice!(0, 4084)
    newsize     = pad4(chunk.bytesize + 10)
    chunk_count += 1
    total_bytes += chunk.bytesize
    log("#{label}: >>> chunk #{chunk_count} CONTINUE 0031;#{newsize}; remaining=#{data.size}")
    safe_write(socket, "0031;#{newsize};#{chunk}", st)
    message = recv_expect(socket, "1030", st, "#{label} chunk #{chunk_count}")
    unless message
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, "#{label}: unexpected response to chunk #{chunk_count}, aborting", '1')
      return
    end
    fields = message.split(";")
    unless fields[0] == "1030"
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, "#{label}: unexpected response #{fields[0].inspect} to chunk #{chunk_count}, aborting", '1')
      return
    end
  end

  len = pad4(data.bytesize + 10)
  total_bytes += data.bytesize
  chunk_count += 1
  log("#{label}: >>> final chunk #{chunk_count} END 0032;#{len}; bytes=#{data.bytesize} total=#{total_bytes}")
  safe_write(socket, "0032;#{len};#{data}", st)

  sleep 2
  message = recv_expect(socket, "1030", st, "#{label} VERTX_SEND_DATA_END")
  fields  = message ? message.split(";") : []

  if fields[0] == "1030"
    log("#{label}: transfer complete. chunks=#{chunk_count} total_bytes=#{total_bytes}")
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "#{label}: File sent successfully! chunks=#{chunk_count} bytes=#{total_bytes}", '3')
  else
    log("#{label}: transfer failed. final response=#{message.inspect}")
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, "#{label}: Error, xfer failed. Response was #{fields[0].inspect}", '1')
  end
rescue IOError, Errno::ECONNRESET => e
  log("#{label}: connection lost: #{e.message}")
  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "#{label}: Connection lost during transfer: #{e.message}", '1')
end

def SendAccessDB(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/NewAccessDB-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/NOC-AccessDB"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/NewAccessDB",
                      File.exist?(path) ? path : fallback,
                      "AccessDB")
end

def SendAccessGroups(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/AccessGroups-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/AccessGroups"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/AccessGroups",
                      File.exist?(path) ? path : fallback,
                      "AccessGroups")
end

def SendCfgFile(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/CfgFile-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/CfgFile"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/CfgFile",
                      File.exist?(path) ? path : fallback,
                      "CfgFile")
end

def SendDBChange(socket, st)
  db_query("UPDATE HIDReaders SET cmd = '0' WHERE mac = ?", st.readermac)
  safe_write(socket, "0052;0015;2000;", st)

  message = recv_expect(socket, "1052", st, "SendDBChange")
  return unless message
  log("Message: #{message}")
  fields = message.split(";")

  if fields[0] == "1052"
    if fields[2] == "0"
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, 'LogMsg 1052: DB Changeover completed', '3')
      db_query("UPDATE HIDReaders SET changeover = CURRENT_TIMESTAMP WHERE mac = ?", st.readermac)
    else
      db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
               st.clientip, "LogMsg 1052: DB Changeover failed with #{fields[2]}, manual review required", '1')
      db_query("UPDATE HIDReaders SET manual_open = '0' WHERE mac = ?", st.readermac)
    end
  end
end

def SendDoorGroups(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/DoorGroups-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/DoorGroups"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/DoorGroups",
                      File.exist?(path) ? path : fallback,
                      "DoorGroups")
end

def Sendeeprom(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/eeprom.properties-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/eeprom.properties"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/eeprom.properties",
                      File.exist?(path) ? path : fallback,
                      "eeprom")
end

def SendEventMsg(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/EventMsg-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/EventMsg"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/EventMsg",
                      File.exist?(path) ? path : fallback,
                      "EventMsg")
end

def SendHolidays(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/Holidays-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/Holidays"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/Holidays",
                      File.exist?(path) ? path : fallback,
                      "Holidays")
end

def SendIdentDB(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/NewIdentDB-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/NOC-IdentDB"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/NewIdentDB",
                      File.exist?(path) ? path : fallback,
                      "IdentDB")
end

def SendInternalID(socket, st)
  path = "/usr/local/sbin/HIDSoft/bin/InternalID-#{st.readermac}"
  unless File.exist?(path)
    log("InternalID: cache miss for #{st.readermac}, pulling from controller")
    result = GetInternalID(socket, st)
    unless result
      log("InternalID: controller fetch failed for #{st.readermac}")
      return
    end
  end
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/InternalID",
                      path,
                      "InternalID")
end

def SendInterfaceBoards(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/InterfaceBoards-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/InterfaceBoards"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/InterfaceBoards",
                      File.exist?(path) ? path : fallback,
                      "InterfaceBoards")
end

def SendInterfaceTypes(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/InterfaceTypes-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/InterfaceTypes"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/InterfaceTypes",
                      File.exist?(path) ? path : fallback,
                      "InterfaceTypes")
end

def SendIOLinker(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/IOLinkerRules-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/IOLinkerRules"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/IOLinkerRules",
                      File.exist?(path) ? path : fallback,
                      "IOLinkerRules")
end

def SendReaders(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/Readers-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/Readers"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/Readers",
                      File.exist?(path) ? path : fallback,
                      "Readers")
end

def SendSchedule(socket, st)
  path     = "/usr/local/sbin/HIDSoft/bin/Schedules-#{st.readermac}"
  fallback = "/usr/local/sbin/HIDSoft/bin/default-3.6.0/Schedules"
  send_file_to_reader(socket, st,
                      "/mnt/flash/TaskConfig/Schedules",
                      File.exist?(path) ? path : fallback,
                      "Schedules")
end

def SetTime(socket, st)
  timestr = Time.new.strftime("%m;%d;%Y;%H;%M;%S;")
  len     = pad4(timestr.length + 10)
  cmd     = "0018;#{len};#{timestr}"
  safe_write(socket, cmd, st)

  message = socket.recv(9000)
  fields  = message.split(";")
  if fields[2] != "0"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Time sync unsuccessful, please contact admin', '3')
  end
end

def SetTimezone(socket, st)
  string = "0088;0018;PST8PDT;"
  db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
           st.clientip, "Setting timezone: #{string}", '3')
  safe_write(socket, string, st)

  message = socket.recv(9000)
  fields  = message.split(";")
  if fields[2] != "0"
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Timezone setup unsuccessful, please contact admin', '3')
  end
end

def strip_header(msg)
  parts = msg.split(";")
  return nil if parts.length < 3
  parts[2..-1].join(";")
end

def transferDB(socket, st)
  res = db_query("SELECT ftp, failcount FROM HIDReaders WHERE mac = ?", st.readermac)
  if res.nil? || res.empty?
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'Call for file transfer invalid, please contact admin', '1')
    return
  end

  row       = res.first
  ftp       = row["ftp"].to_i
  failcount = row["failcount"].to_i

  if ftp == 1
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'FTP: File transfer in progress.', '3')
    ftpReader(socket, st)
  elsif failcount == 5
    db_query("INSERT INTO HIDSoftLog (device, message, type) VALUES (?, ?, ?)",
             st.clientip, 'File transfer failing, converting to FTP', '3')
    db_query("UPDATE HIDReaders SET ftp = '1' WHERE mac = ?", st.readermac)
    ftpReader(socket, st)
  else
    SendAccessDB(socket, st)
    SendIdentDB(socket, st)
  end
end

def recv_expect(socket, expected_code, st, context = "")
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
      db_query("INSERT INTO HIDActive SET mac = ?, ip = ?, timestamp = NOW() " \
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
## v2.6.0 - Replaced persistent DbHandle pattern with per-query open/close via db_query().
##          No DB connection is held open between queries anywhere in the process.
##          Removed DbHandle struct entirely. Removed db parameter from all method signatures.
##          Removed thread_db locals and their ensure/close blocks from Thread.new spawns.
##          Set reconnect: false in db_connect since each connection is used once and closed.
##          Removed ensure db&.close from ChildProc (no persistent handle to close).
## v2.5.2 - Full DbHandle migration: all sqlq() calls replaced with db.query(),
##          all threads use their own DbHandle, ensure closes db correctly.
##          Extracted send_file_to_reader() helper to eliminate Send* duplication.
## v2.5.1 - Added send functions for AccessGroups, CfgFile, DoorGroups, EventMsg, InterfaceBoards,
##          InterfaceTypes, InternalID, Readers, eeprom.properties
## v2.5 - Adjusted to use 0060, or pull method on the readers instead of requiring them to send on read.
## v2.4 - Updated for use with ruby 2.5 and mysql2 gem
