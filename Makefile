all:
	mkdir -p ebin
	(cd src;$(MAKE))

clean:
	(cd src;$(MAKE) clean)

