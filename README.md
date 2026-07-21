# HIDSoft

Sorry, still working out the full instruction set.  important details you should know, 

System Requirements: Linux (your flavor should  work, I have tested on Debian, Centos and Alma), Mariadb (does not necessarily need a specific version, but to be consistent I built with 10.3), and ruby 2.5 (should be compatible with 3.0, but untested), mysql2 gem.

Install path, /usr/local/sbin/HIDSoft
Copy the bin folder under that

Add new user cardreader, does not need special permissions, just enough to run the systemd service and open the tcp port.  
Open the port on your firewall 4070, expose to the network you expect readers on, suggestion is keep these internal as they are running over insecure channels.

setup the HIDSoft.service (depending on your platform), and enable/start it.

Depending on the volume of readers, suggest testing reader builds depending on hardware, with my build environment and 60 readers, the access/ident build time took about 10 minutes per build cycle, but that might have been disk related.  Setup a cron to run /usr/local/sbin/HIDSoft/bin/builddb.sh as cardreader user, so you can create the files with the right permissions.

From here, point your readers at the server, the control server IP should be the server address of your server.  If you monitor the software, you should see a HIDSoft ChildProcess start for each of the readers as they connect.  They should also automatically enter into the database as blank, updated the time on the readers and begin the proceess of getting them ready for initial use. You should be able to monitor this via the logs.
