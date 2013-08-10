virtclone
=========

Copies /var/lib/libvirt/images/debianbase.img (a base install of debian wheezy) to new hostname.
Mounts the new fs and modifies hostname and ssh keys.
Adds new uuid and mac address to .xml file, as well as cpu cores and memory if specified.
Updates dhcpd.conf on dhcp server with static ip if specified.


	Usage:
	./virtclone.sh hostname [options]

	Options:
 	-a <address>  	    Specifies a static IP address for guest
 	-c <num>		        Number of cores the guest can use
 	-m <num>		        The amount of memory the guest can use
 	-n <hostname>		  Name for the new KVM guest
 	-A			            Autostart guest at boot time
 	-S  		            Start guest as soon as configuration has finished

