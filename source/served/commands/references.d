module served.commands.references;

import core.sync.mutex;
import core.thread;

import served.types;
import served.utils.async;

import workspaced.com.dcd;
import workspaced.com.index;
import workspaced.com.references;

@protocolMethod("textDocument/references")
AsyncReceiver!Location findReferences(ReferenceParams params)
{
	auto receiver = new AsyncReceiver!Location();
	scope document = documents[params.textDocument.uri];
	auto offset = cast(int) document.positionToBytes(params.position);
	string file = document.uri.uriToFile;
	scope codeText = document.rawText;

	if (!backend.hasBest!DCDComponent(file))
	{
		receiver.end();
		return receiver;
	}

	bool includeDecl = params.context.includeDeclaration;
	setImmediate({
		scope (exit)
			receiver.end();

		try
		{
			backend.best!ReferencesComponent(file)
				.findReferences(file, codeText, offset,
				(refs) {
					Location[] ret;
					foreach (r; refs.references)
					{
						if (!includeDecl && refs.definitionFile == r.file && refs.definitionLocation == r.location)
							continue;
						resolveLocation(ret, r.file, r.location);
					}
					receiver.put(ret);
				});
		}
		catch (Exception e)
		{
			receiver.error = e;
		}
	});
	return receiver;
}

private void resolveLocation(ref Location[] ret, string file, int location)
{
	auto uri = file.uriFromFile;
	scope doc = documents.getOrFromFilesystem(uri);
	auto pos = doc.bytesToPosition(location);
	ret ~= Location(uri, doc.wordRangeAt(pos));
}

class AsyncReceiver(T)
{
	bool notified;
	Mutex m;
	Exception error;
	T[] queued;
	T[] current;

	this()
	{
		m = new Mutex();
	}

	bool ended;

	T[] front()
	{
		if (error)
			throw error;
		return current;
	}

	void popFront()
	{
		if (error)
			throw error;
		if (ended)
		{
			current = queued;
			queued = null;
			return;
		}

		wait();

		synchronized (m)
		{
			notified = false;
			current = queued;
			queued = null;
		}
	}

	bool empty()
	{
		if (error)
			throw error;
		return ended && current.length == 0;
	}

	void put(T[] data)
	{
		if (!data.length)
			return;

		synchronized (m)
		{
			queued ~= data;
			notified = true;
		}
	}

	void wait()
	{
		while (!notified)
			Fiber.yield();
	}

	void end()
	{
		ended = true;
		synchronized (m)
		{
			notified = true;
		}
	}
}
