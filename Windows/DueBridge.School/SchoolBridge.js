// Evaluated only in a fresh isolated world on the exact school origin.
// Cookies and the MO bearer remain in this world and are never returned.
async ({ platform, path, body, expected }) => {
    const mo = platform === "mo";
    const origin = mo ? "https://mo.zju.edu.cn" : "https://courses.zju.edu.cn";
    if ((!mo && platform !== "learning-in-zju") || location.origin !== origin) return { error: "unsafe" };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 25000);
    const limit = 8 * 1024 * 1024;
    const validId = value => typeof value === "string" && value.trim().length > 0 &&
        new TextEncoder().encode(value).length <= 1024 && !/[\u0000-\u001f\u007f-\u009f]/.test(value);
    function moBinding() {
        const id = localStorage.getItem("user_obj_id");
        const user = localStorage.getItem("user_ID");
        const token = localStorage.getItem("token");
        if (!validId(id) || !validId(user) || user === "." || user === ".." ||
            typeof token !== "string" || token.length === 0 || token.length > 32768 || /[\r\n]/.test(token))
            throw "login";
        return { id, user, token };
    }
    async function read(relative, payload, html = false) {
        const url = new URL(relative, origin);
        if (url.origin !== origin || url.username || url.password || url.hash) throw "unsafe";
        const headers = { Accept: html ? "text/html" : "application/json" };
        if (mo) headers.Authorization = "Bearer " + moBinding().token;
        if (payload !== null) {
            headers["Content-Type"] = "application/json";
            const csrf = document.cookie.split(";").map(value => value.trim()).find(value => value.startsWith("XSRF-TOKEN="));
            if (csrf) headers["X-XSRF-TOKEN"] = decodeURIComponent(csrf.slice(11));
        }
        const response = await fetch(url.href, {
            method: payload === null ? "GET" : "POST", body: payload === null ? undefined : payload, headers,
            credentials: "same-origin", redirect: "error", cache: "no-store", signal: controller.signal
        });
        if (response.status === 401 || response.status === 403) throw "login";
        if (response.status === 429 || response.status >= 500) throw "network";
        if (!response.ok || response.redirected) throw "invalid";
        const mime = (response.headers.get("Content-Type") || "").split(";")[0].trim().toLowerCase();
        if (html ? mime !== "text/html" : !/^application\/(?:json|[a-z0-9.+-]+\+json)$/.test(mime)) throw "invalid";
        if (Number(response.headers.get("Content-Length")) > limit || !response.body) throw "invalid";
        const reader = response.body.getReader();
        const decoder = new TextDecoder("utf-8", { fatal: true });
        const chunks = [];
        let bytes = 0;
        try {
            for (;;) {
                const { value, done } = await reader.read();
                if (done) break;
                bytes += value.length;
                if (bytes > limit) throw "invalid";
                chunks.push(decoder.decode(value, { stream: true }));
            }
        } finally {
            reader.releaseLock();
        }
        chunks.push(decoder.decode());
        return chunks.join("");
    }
    function isCatalogPath() {
        if (typeof path !== "string" || path.length > 8192) return false;
        if (mo) return body === null && (
            /^\/pyapi\/course\?group=my&type=all&learning_status=(?:pending|learning|finished)&page_no=[1-9][0-9]?&page_size=100$/.test(path) ||
            /^\/pyapi\/course\/section\/[a-zA-Z0-9_.~%\-]+\?is_backstage=false$/.test(path));
        if (path === "/api/my-courses") {
            if (typeof body !== "string" || body.length > 1024) return false;
            const fields = JSON.parse(body);
            return Object.keys(fields).length === 4 && fields.page_size === 100 && fields.fields === "id,name" &&
                Number.isInteger(fields.page) && fields.page >= 1 && fields.page <= 100 &&
                fields.conditions && Object.keys(fields.conditions).length === 2 && fields.conditions.keyword === "" &&
                JSON.stringify(fields.conditions.status) === '["ongoing","notStarted","ended"]';
        }
        return body === null && (
            /^\/api\/course\/[a-zA-Z0-9_.~%\-]+\/homework-scores\?fields=id,title,data,start_time,end_time,published,is_in_progress$/.test(path) ||
            /^\/api\/courses\/[a-zA-Z0-9_.~%\-]+\/exams$/.test(path));
    }
    try {
        if (path !== null) {
            if (!isCatalogPath()) return { error: "unsafe" };
            if (mo && moBinding().id !== expected) return { error: "account" };
            const text = await read(path, body);
            if (mo && moBinding().id !== expected) return { error: "account" };
            return { value: text };
        }
        if (mo) {
            const binding = moBinding();
            const payload = JSON.parse(await read("/pyapi/user/profile/" + encodeURIComponent(binding.user), null));
            const profile = payload.response === undefined ? payload : payload.response;
            if (!profile || profile._id !== binding.id ||
                (profile.user_ID !== undefined && String(profile.user_ID) !== binding.user)) return { error: "login" };
            const current = moBinding();
            return current.id === binding.id && current.user === binding.user ? { value: binding.id } : { error: "account" };
        }
        const page = new DOMParser().parseFromString(await read("/user/index", null, true), "text/html");
        const field = page.querySelector("#userId");
        const identity = field && (field.getAttribute("data-id") || field.value || field.getAttribute("value"));
        return validId(identity) ? { value: identity } : { error: "login" };
    } catch (error) {
        if (controller.signal.aborted) return { error: "timeout" };
        if (["login", "account", "invalid", "unsafe", "network"].includes(error)) return { error };
        return { error: error instanceof TypeError ? "network" : "invalid" };
    } finally {
        clearTimeout(timer);
        controller.abort();
    }
}
