LIBDIR=`erl -eval 'io:format("~s~n", [code:lib_dir()])' -s init stop -noshell`
VERSION=1

all:
	mkdir -p ebin
	(cd src;$(MAKE))

clean:
	(cd src;$(MAKE) clean)

dist-src:
	tar zcf mysql-1.tgz src/ include/ support/ Makefile README

package: clean
	@mkdir erlang_mysql-$(VERSION)/ && cp -rf src/ include/ support/ Makefile README erlang_mysql-$(VERSION)
	@COPYFILE_DISABLE=true tar zcf erlang_mysql-$(VERSION).tgz erlang_mysql-$(VERSION)
	@rm -rf erlang_mysql-$(VERSION)/
		
install:
	mkdir -p $(prefix)/$(LIBDIR)/erlang_mysql-$(VERSION)/{ebin,include}
	for i in ebin/*.beam; do install $$i $(prefix)/$(LIBDIR)/erlang_mysql-$(VERSION)/$$i ; done
