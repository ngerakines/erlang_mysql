all:
	mkdir -p ebin
	(cd src;$(MAKE))

clean:
	(cd src;$(MAKE) clean)

dist-src:
	tar zcf mysql-1.tgz src/ include/ support/ Makefile

