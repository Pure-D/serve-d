/**
 * This file is licensed under the MIT License.
 * 
 * Some code taken from https://github.com/actions/upload-release-asset
 */

const core = require("@actions/core");
const { GitHub } = require("@actions/github");
const fs = require("fs");

/**
 * 
 * @param {GitHub} github 
 * @param {*} name 
 */
async function uploadAsset(github, name) {
	const url = core.getInput("upload_url", { required: true });
	const assetPath = core.getInput("asset_path", { required: true });
	const contentType = core.getInput("asset_content_type", { required: true });

	const contentLength = filePath => fs.statSync(filePath).size;

	const headers = { 'content-type': contentType, 'content-length': contentLength(assetPath) };

	const uploadAssetResponse = await github.repos.uploadReleaseAsset({
		url,
		headers,
		name,
		file: fs.readFileSync(assetPath)
	});

	return uploadAssetResponse.data.value.browser_download_url;
}

async function run() {
	try {
		const maxReleases = parseInt(core.getInput("max_releases", { required: false }));
		const releaseId = core.getInput("release_id", { required: true });
		let name = core.getInput("asset_name", { required: true });
		const placeholderStart = name.indexOf("$$");
		const nameStart = name.substr(0, placeholderStart);
		const nameEnd = name.substr(placeholderStart + 2);

		const github = new GitHub(process.env.GITHUB_TOKEN);
		const hash = process.env.GITHUB_SHA.substr(0, 6);
		const repository = process.env.GITHUB_REPOSITORY.split('/');
		const owner = repository[0];
		const repo = repository[1];

		core.info("Checking previous assets");
		let assets = await github.repos.listAssetsForRelease({
			owner: owner,
			repo: repo,
			release_id: parseInt(releaseId)
		});

		assets.data.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));

		let numFound = 0;
		for (let i = 0; i < assets.data.length; i++) {
			const asset = assets.data[i];
			if (asset.name.startsWith(nameStart) && asset.name.endsWith(nameEnd)) {
				if (asset.name.endsWith("-" + hash + nameEnd)) {
					core.info("Current commit already released, exiting");
					core.setOutput("uploaded", "no");
					return;
				} else {
					numFound++;
					if (numFound >= maxReleases) {
						core.info("Queuing old asset " + asset.name + " for deletion");
						toDelete.push(asset.id);
					}
				}
			}
		}

		let now = new Date();
		let date = now.getUTCFullYear().toString() + pad2(now.getUTCMonth().toString()) + pad2(now.getUTCDate().toString());

		name = name.replace("$$", date + "-" + hash);

		let url = await uploadAsset(github, name);

		core.info("Deleting " + toDelete.length + " old assets");
		for (let i = 0; i < toDelete.length; i++) {
			const id = toDelete[i];
			await github.repos.deleteReleaseAsset({
				owner: owner,
				repo: repo,
				asset_id: id
			});
		}

		core.setOutput("uploaded", "yes");
		core.setOutput("url", url);
	} catch (error) {
		core.setFailed(error.message);
	}
}

function pad2(v) {
	v = v.toString();
	while (v.length < 2) v = "0" + v;
	return v;
}

run();
