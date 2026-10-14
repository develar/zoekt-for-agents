package main

import (
	"bufio"
	"os"
)

func bufferedStdout() *bufio.Writer { return bufio.NewWriterSize(os.Stdout, 1<<16) }
