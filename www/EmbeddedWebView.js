// EmbeddedWebView.js (multi-instance, per-id events)

let exec = require('cordova/exec');

let EmbeddedWebView = {
    /**
     * Create and show an embedded WebView instance
     * @param {string} id - Unique instance id for this WebView (e.g. 'classroom', 'payment')
     * @param {string} url - URL to load
     * @param {object} options - Layout and configuration options
     * @param {number} options.top - Top offset in pixels (distance from top of screen)
     * @param {number} options.height - Height in pixels (visible area for the WebView)
     * @param {object} [options.headers] - Optional custom HTTP headers
     * @param {string} [options.progressColor] - Optional progress bar color
     * @param {number} [options.progressHeight] - Optional progress bar height
     * @param {boolean} [options.enableZoom=false] - Enable zoom controls
     * @param {boolean} [options.clearCache=false] - Clear cache before loading
     * @param {string} [options.userAgent] - Custom User-Agent string
     * @param {function} [successCallback]
     * @param {function} [errorCallback]
     */
    create: function (id, url, options, successCallback, errorCallback) {
        options = options || {};

        // Validations
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        if (!url || typeof url !== 'string') {
            errorCallback && errorCallback('URL must be a non-empty string');
            return;
        }

        if (typeof options.top !== 'number') {
            options.top = 0;
        }

        if (typeof options.height !== 'number') {
            options.height = window.innerHeight;
        }

        exec(
            successCallback,
            errorCallback,
            'EmbeddedWebView',
            'create',
            [id, url, options]
        );
    },

    /**
     * Destroy a specific embedded WebView instance
     * @param {string} id
     */
    destroy: function (id, successCallback, errorCallback) {
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        exec(successCallback, errorCallback, 'EmbeddedWebView', 'destroy', [id]);
    },

    /**
     * Navigate to a new URL in a specific WebView instance
     * @param {string} id
     * @param {string} url
     * @param {object|function} [headers]
     */
    loadUrl: function (id, url, headers, successCallback, errorCallback) {
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        if (!url || typeof url !== 'string') {
            errorCallback && errorCallback('URL must be a non-empty string');
            return;
        }

        if (typeof headers === 'function') {
            errorCallback = successCallback;
            successCallback = headers;
            headers = null;
        }

        exec(
            successCallback,
            errorCallback,
            'EmbeddedWebView',
            'loadUrl',
            [id, url, headers || null]
        );
    },

    /**
     * Execute JavaScript in a specific embedded WebView instance
     * @param {string} id
     * @param {string} script
     */
    executeScript: function (id, script, successCallback, errorCallback) {
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        if (!script || typeof script !== 'string') {
            errorCallback && errorCallback('script must be a non-empty string');
            return;
        }

        exec(
            successCallback,
            errorCallback,
            'EmbeddedWebView',
            'executeScript',
            [id, script]
        );
    },

    /**
     * Show or hide a specific WebView instance
     * @param {string} id
     * @param {boolean} visible
     */
    setVisible: function (id, visible, successCallback, errorCallback) {
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        exec(
            successCallback,
            errorCallback,
            'EmbeddedWebView',
            'setVisible',
            [id, !!visible]
        );
    },

    /**
     * Reload a specific WebView instance
     * @param {string} id
     */
    reload: function (id, successCallback, errorCallback) {
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        exec(successCallback, errorCallback, 'EmbeddedWebView', 'reload', [id]);
    },

    /**
     * Go back in history for a specific WebView instance
     * @param {string} id
     */
    goBack: function (id, successCallback, errorCallback) {
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        exec(successCallback, errorCallback, 'EmbeddedWebView', 'goBack', [id]);
    },

    /**
     * Go forward in history for a specific WebView instance
     * @param {string} id
     */
    goForward: function (id, successCallback, errorCallback) {
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        exec(successCallback, errorCallback, 'EmbeddedWebView', 'goForward', [id]);
    },

    /**
     * Ask native if this instance can go back
     * @param {string} id
     */
    canGoBack: function (id, successCallback, errorCallback) {
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        exec(successCallback, errorCallback, 'EmbeddedWebView', 'canGoBack', [id]);
    },

    /**
     * Helper: Inject authentication token into a specific instance (storage-safe)
     */
    injectAuthToken: function (id, token, storageType, key, successCallback, errorCallback) {
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        storageType = storageType || 'localStorage';
        key = key || 'authToken';

        const safeKey = String(key);
        const safeToken = token == null ? '' : String(token);

        const script =
            `${storageType}.setItem(${JSON.stringify(safeKey)}, ${JSON.stringify(safeToken)});`;

        this.executeScript(id, script, successCallback, errorCallback);
    },

    /**
     * Helper: Get a storage value from a specific instance (storage-safe)
     */
    getStorageValue: function (id, key, storageType, successCallback, errorCallback) {
        if (!id || typeof id !== 'string') {
            errorCallback && errorCallback('id must be a non-empty string');
            return;
        }

        storageType = storageType || 'localStorage';
        const safeKey = String(key);

        const script =
            `${storageType}.getItem(${JSON.stringify(safeKey)});`;

        this.executeScript(id, script, successCallback, errorCallback);
    },

    /**
     * Add event listener for WebView events for a specific instance.
     *
     * Native now fires:
     *   cordova.fireDocumentEvent('embeddedwebview.<id>.<eventName>', { detail: ... });
     *
     * @param {string} id - WebView instance id
     * @param {string} eventName - loadStart, loadStop, loadError,
     *                             navigationStateChanged, canGoBackChanged, canGoForwardChanged
     * @param {function} callback - (event) => {}
     */
    addEventListener: function (id, eventName, callback) {
        if (typeof callback !== 'function') {
            console.error('Callback must be a function');
            return;
        }

        if (!id || typeof id !== 'string') {
            console.error('id must be a non-empty string');
            return;
        }

        let eventFullName = 'embeddedwebview.' + id + '.' + eventName;
        document.addEventListener(eventFullName, callback, false);
    },

    /**
     * Remove event listener for a specific instance
     * @param {string} id
     * @param {string} eventName
     * @param {function} callback
     */
    removeEventListener: function (id, eventName, callback) {
        if (!id || typeof id !== 'string') {
            console.error('id must be a non-empty string');
            return;
        }

        let eventFullName = 'embeddedwebview.' + id + '.' + eventName;
        document.removeEventListener(eventFullName, callback, false);
    }
};

module.exports = EmbeddedWebView;
