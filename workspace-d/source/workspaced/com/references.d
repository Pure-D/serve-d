module workspaced.com.references;

import workspaced.api;
import workspaced.helpers;

import workspaced.com.dcd;
import workspaced.com.index;
import workspaced.com.moduleman;

import std.file;

@component("references")
class ReferencesComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		if (!refInstance)
			throw new Exception("references component requires to be instanced");
	}

	/// basic text-search-based references lookup
	Future!References findReferences(string file, scope const(char)[] code, int pos)
	{
		auto future = new typeof(return);
		auto declTask = get!DCDComponent.findDeclaration(code, pos);
		declTask.onDone({
			try
			{
				References ret;

				auto decl = declTask.getImmediately;
				if (decl is DCDDeclaration.init)
					return future.finish(References.init);

				if (decl.file == "stdin")
					decl.file = file;

				ret.definitionFile = decl.file;
				ret.definitionLocation = cast(int)decl.position;

				scope definitionCode = readText(decl.file);
				string identifier = getIdentifierAt(definitionCode, decl.position).idup;
				string startModule = get!ModulemanComponent.moduleName(definitionCode);

				auto localUseTask = get!DCDComponent.findLocalUse(
					definitionCode, ret.definitionLocation);
				localUseTask.onDone({
					try
					{
						auto localUse = localUseTask.getImmediately;
						if (localUse.declarationFilePath == "stdin")
							localUse.declarationFilePath = ret.definitionFile;

						foreach (use; localUse.uses)
							ret.references ~= References.Reference(
								localUse.declarationFilePath, cast(int)use);

						if (identifier.length)
						{
							bool[ModuleRef] visited;
							grepRecursive(ret,
								startModule,
								identifier,
								visited);
						}
						future.finish(ret);
					}
					catch (Throwable t)
					{
						future.error(t);
					}
				});
			}
			catch (Throwable t)
			{
				future.error(t);
			}
		});
		return future;
	}

private:
	void grepRecursive(ref References ret, ModuleRef start, string identifier,
		ref bool[ModuleRef] visited)
	{
		if (start in visited)
			return;
		visited[start] = true;

		get!IndexComponent.iterateModuleReferences(start, (other) {
			auto filename = get!IndexComponent.getIndexedFileName(other);
			scope content = readText(filename);
			grepFileReferences(ret, content, filename, identifier);

			grepRecursive(ret, other, identifier, visited);
		});
	}

	static void grepFileReferences(ref References ret, scope const(char)[] code, string file, string identifier)
	{
		ptrdiff_t i = 0;
		while (true)
		{
			i = indexOfKeyword(code, identifier, i);
			if (i == -1)
				break;
			ret.references ~= References.Reference(file, cast(int)i);
			i++;
		}
	}
}

struct References
{
	struct Reference
	{
		string file;
		int location;
	}

	string definitionFile;
	int definitionLocation;
	Reference[] references;
}
