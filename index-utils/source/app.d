import std.algorithm;
import std.stdio;
import workspaced.index_format;

void main()
{
	IndexCache index = IndexCache.load;
	writeln("index: ", index.fileName);
	writeln("indexed files: ", index.getIndexedFiles.length);
	auto files = cast(IndexCache.IndexedFile[])index.getIndexedFiles;
	foreach (file; files.sort!"a.fileName<b.fileName")
	{
		writeln("\t", file.fileName,
			"\t(", file.fileSize,
			"B)\t= ", file.modName,
			"\t", file.elements.length, " elements",
			"\t", file.hasMixin ? "has mixin" : "no flags");
	}
}
