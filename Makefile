all:
	mkdir -p ebin
	(cd src;$(MAKE))

clean:
	(cd src;$(MAKE) clean)

dist-src:
	mkdir erlang_mysql-1/ && cp -rfv src include support Makefile erlang_mysql-1/
	tar zcf mysql-1.tgz erlang_mysql-1
