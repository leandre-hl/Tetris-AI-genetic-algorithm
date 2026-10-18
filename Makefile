OCAMLC = ocamlc
OCAMLFLAGS = -w +a-70
LIBS = unix.cma
INCLUDES = -I +domainslib

SRC = src/tetris.ml src/genetic.ml
MAIN = bin/main.ml

.PHONY: all run clean

all: main

main: src/tetris.ml src/genetic.ml bin/main.ml
	$(OCAMLC) $(OCAMLFLAGS) $(INCLUDES) -c src/tetris.ml
	$(OCAMLC) $(OCAMLFLAGS) $(INCLUDES) -c -o src/genetic.cmo src/genetic.ml
	$(OCAMLC) $(OCAMLFLAGS) $(INCLUDES) -c -o bin/main.cmo bin/main.ml
	$(OCAMLC) $(OCAMLFLAGS) $(INCLUDES) -o main $(LIBS) src/tetris.cmo src/genetic.cmo bin/main.cmo

run: main
	./main

clean:
	rm -f main src/*.cmi src/*.cmo bin/*.cmi bin/*.cmo