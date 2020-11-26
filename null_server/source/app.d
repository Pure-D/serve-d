static import null_server.extension;

import served.serverbase;

int main(string[] args)
{
	mixin LanguageServerRouter!(null_server.extension) server;

	return server.run() ? 0 : 1;
}
