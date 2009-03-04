LIBDIR=`erl -eval 'io:format("~s~n", [code:lib_dir()])' -s init stop -noshell`
VERSION=1

all:
	mkdir -p ebin
	(cd src;$(MAKE))

clean:
	(cd src;$(MAKE) clean)

dist-src:
	tar zcf mysql-1.tgz src/ include/ support/ Makefile
	
install:
	mkdir -p $(prefix)/$(LIBDIR)/mysql-$(VERSION)/{ebin,include}
	for i in ebin/*.beam; do install $$i $(prefix)/$(LIBDIR)/mysql-$(VERSION)/$$i ; done

