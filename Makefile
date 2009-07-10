LIBDIR=`erl -eval 'io:format("~s~n", [code:lib_dir()])' -s init stop -noshell`
VERSION=3

all:
	mkdir -p ebin
	(cd src;$(MAKE))

clean:
	(cd src;$(MAKE) clean)

package: clean
	@mkdir erlang_mysql-$(VERSION)/ && cp -rf src include support Makefile README erlang_mysql-$(VERSION)
	@COPYFILE_DISABLE=true tar zcf erlang_mysql-$(VERSION).tgz erlang_mysql-$(VERSION)
	@rm -rf erlang_mysql-$(VERSION)/
		
install:
	mkdir -p $(prefix)/$(LIBDIR)/erlang_mysql-$(VERSION)/{ebin,include}
	for i in ebin/*.beam include/*.hrl; do install $$i $(prefix)/$(LIBDIR)/erlang_mysql-$(VERSION)/$$i ; done

test: all
	prove t/*.t
