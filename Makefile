

PACKAGES=async fileutils core.syntax camlp4 bin_prot.syntax sexplib.syntax postgresql cmdliner async_shell extunix core core_extended
# I don't understand warning 18
OPTIONS=-tag annot -no-sanitize -no-links -tag debug -use-ocamlfind -cflags -w,+a-4-9-18-41-30-42-44-40 -cflags -warn-error,+5+10+8+12+20+11 -cflag -bin-annot -j 8 -tag thread -syntax camlp4o
#OPTIONS += -cflags -warn-error,+a
DIRECTORIES=src/common src/monitor src/utils src/clients_lib src/conductor tests src/script src src/wrapper
OCAMLBUILD=ocamlbuild \
		 $(addprefix -package ,$(PACKAGES)) \
		 $(OPTIONS)	\
		 $(addprefix -I ,$(DIRECTORIES)) \

.PHONY: tests monitor.native tests_table.native tests_table.byte

BINARY= src/wrapper/Oci_Wrapper.native				\
	src/monitor/Oci_Simple_Exec.native tests/myoci.native	\
	tests/test_succ_runner.native tests/launch_test.native  \
	src/monitor/Oci_Monitor.native

all: .merlin
	@mkdir -m 777 -p bin
	@rm -f bin/*.native
	$(OCAMLBUILD) src/clients_lib/Oci_Master.cmxa src/clients_lib/Oci_Runner.cmxa $(BINARY)
	@cp $(addprefix _build/,$(BINARY)) bin

#force allows to always run the rules that depends on it
.PHONY: force

GIT_VERSION:=$(shell git describe --tags --dirty)

#.git_version remember the last version for knowing when rebuilding
.git_version: force
	@echo '$(GIT_VERSION)' | cmp -s - $@ || echo '$(GIT_VERSION)' > $@

src/version.ml: .git_version Makefile
	@echo "Generating $@ for version $(GIT_VERSION)"
	@rm -f $@.tmp
	@echo "(** Autogenerated by makefile *)" > $@.tmp
	@echo "let version = \"$(GIT_VERSION)\"" >> $@.tmp
	@chmod a=r $@.tmp
	@mv -f $@.tmp $@

bin/%.native: src/version.ml force
	@mkdir -p `dirname bin/$*.native`
	@rm -f $@
	@$(OCAMLBUILD) src/$*.native
	@ln -rs _build/src/$*.native $@

monitor.byte:
	$(OCAMLBUILD) src/monitor/monitor.byte

tests_table.byte:
	$(OCAMLBUILD) tests/tests_table.byte


#Because ocamlbuild doesn't give to ocamldoc the .ml when a .mli is present
dep:
	cd _build; \
	ocamlfind ocamldoc -o dependencies.dot $$(find src -name "*.ml" -or -name "*.mli") \
	$(addprefix -package ,$(PACKAGES)) \
	$(addprefix -I ,$(DIRECTORIES)) \
	-dot -dot-reduce
	sed -i -e "s/  \(size\|ratio\|rotate\|fontsize\).*$$//" _build/dependencies.dot
	dot _build/dependencies.dot -T svg > dependencies.svg

clean:
	rm -rf bin
	ocamlbuild -clean

.merlin: Makefile
	@echo "Generating Merlin files"
	@rm -f .merlin.tmp
	@for PKG in $(PACKAGES); do echo PKG $$PKG >> .merlin.tmp; done
	@for SRC in $(DIRECTORIES); do echo S $$SRC >> .merlin.tmp; done
	@for SRC in $(DIRECTORIES); do echo B _build/$$SRC >> .merlin.tmp; done
	@mv .merlin.tmp .merlin
