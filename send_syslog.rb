require 'socket'
s = UDPSocket.new
s.send("hello dudes hahhahahahahahahahah", 0, 'netmon02.opticfusion.net', 514)
