LIBDIR=`erl -eval 'io:format("~s~n", [code:lib_dir()])' -s init stop -noshell`

all:
	mkdir -p ebin
	(cd src;$(MAKE))

clean:
	(cd src;$(MAKE) clean)

dist-src:
	mkdir erlang_mysql-1/ && cp -rfv src include support Makefile erlang_mysql-1/
	tar zcf mysql-1.tgz erlang_mysql-1

install: all
	mkdir -p ${LIBDIR}/mysql-1/{ebin,include}
	for i in ebin/*.beam; do install $$i $(LIBDIR)/mysql-1/$$i ; done
