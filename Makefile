LIBDIR=`erl -eval 'io:format("~s~n", [code:lib_dir()])' -s init stop -noshell`
VERSION=3
PKGNAME=erlang_mysql

all: app
	mkdir -p ebin
	(cd src;$(MAKE))

app:
	sh ebin/mysql.app.in $(VERSION)

clean:
	(cd src;$(MAKE) clean)
	rm -rf ebin/*.app cover

package: clean
	@mkdir erlang_mysql-$(VERSION)/ && cp -rf ebin src include support Makefile README erlang_mysql-$(VERSION)
	@COPYFILE_DISABLE=true tar zcf erlang_mysql-$(VERSION).tgz erlang_mysql-$(VERSION)
	@rm -rf erlang_mysql-$(VERSION)/
		
install:
	mkdir -p $(prefix)/$(LIBDIR)/erlang_mysql-$(VERSION)/{ebin,include}
	for i in ebin/*.beam ebin/*.app include/*.hrl; do install $$i $(prefix)/$(LIBDIR)/erlang_mysql-$(VERSION)/$$i ; done

test: all
	prove t/*.t

cover: all
	COVER=1 prove t/*.t
	erl -detached -noshell -eval 'etap_report:create()' -s init stop