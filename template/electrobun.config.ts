import type { ElectrobunConfig } from "electrobun";

export default {
	app: {
		name: "my-electrobun-app",
		identifier: "com.example.my-electrobun-app",
		version: "0.1.0",
	},
	build: {
		views: {
			mainview: {
				entrypoint: "src/mainview/index.ts",
			},
		},
		copy: {
			"src/mainview/index.html": "views/mainview/index.html",
			"src/mainview/index.css": "views/mainview/index.css",
		},
		// Use system WebView (WebKit on Linux/macOS, WebView2 on Windows)
		// instead of bundling Chromium Embedded Framework.
		// Set to true if you need a specific Chromium version.
		mac: {
			bundleCEF: false,
		},
		linux: {
			bundleCEF: false,
		},
		win: {
			bundleCEF: false,
		},
	},
} satisfies ElectrobunConfig;
