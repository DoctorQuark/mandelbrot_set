const BufferedWriter = std.io.BufferedWriter(4096, std.fs.File.Writer).Writer;
const BufferedReader = std.io.BufferedReader(4096, std.fs.File.Reader).Reader;

pub const Stderr = BufferedWriter;
pub const Stdout = BufferedWriter;
pub const Stdin = BufferedReader;

const std = @import("std");
