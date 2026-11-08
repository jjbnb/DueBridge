const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

const script = readFileSync(join(__dirname, "../DueBridge.School/SchoolBridge.js"), "utf8");
const moOrigin = "https://mo.zju.edu.cn";
const learningOrigin = "https://courses.zju.edu.cn";
const coursePath = "/pyapi/course?group=my&type=all&learning_status=learning&page_no=1&page_size=100";

function harness(origin, send, cookie = "") {
    const local = new Map([["user_obj_id", "account-a"], ["user_ID", "fixture"], ["token", "synthetic-fixture"]]);
    const read = vm.runInNewContext("(" + script + ")", {
        location: { origin }, localStorage: { getItem: name => local.get(name) ?? null }, document: { cookie },
        TextEncoder, TextDecoder, URL, AbortController, setTimeout, clearTimeout,
        fetch: send
    });
    return { local, read };
}

test("origin and request path are checked before network access", async () => {
    const never = () => assert.fail("unexpected school request");
    const parameters = { platform: "mo", path: coursePath, body: null, expected: "account-a" };
    assert.equal((await harness("https://example.invalid", never).read(parameters)).error, "unsafe");
    assert.equal((await harness(moOrigin, never).read({ ...parameters, path: "/pyapi/admin" })).error, "unsafe");
    assert.equal((await harness(moOrigin, never).read({ ...parameters, expected: "other" })).error, "account");
});

test("MO identity is verified on the school origin without returning its bearer", async () => {
    const session = harness(moOrigin, async (url, options) => {
        assert.equal(url, moOrigin + "/pyapi/user/profile/fixture");
        assert.equal(options.headers.Authorization, "Bearer synthetic-fixture");
        assert.equal(options.redirect, "error");
        return Response.json({ response: { _id: "account-a", user_ID: "fixture" } });
    });
    const result = await session.read({ platform: "mo", path: null, body: null, expected: null });
    assert.equal(JSON.stringify(result), '{"value":"account-a"}');
});

test("school account changes during a read discard the payload", async () => {
    const session = harness(moOrigin, async () => {
        session.local.set("user_obj_id", "account-b");
        return Response.json({ objects: [], count: 0 });
    });
    assert.equal((await session.read({ platform: "mo", path: coursePath, body: null, expected: "account-a" })).error, "account");
});

test("learning site sends only the fixed course search POST", async () => {
    let calls = 0;
    const session = harness(learningOrigin, async (url, options) => {
        calls++;
        assert.equal(url, learningOrigin + "/api/my-courses");
        assert.equal(options.method, "POST");
        assert.equal(options.headers["X-XSRF-TOKEN"], "synthetic=fixture");
        assert.equal(options.credentials, "same-origin");
        return Response.json({ courses: [], total: 0 });
    }, "XSRF-TOKEN=synthetic%3Dfixture");
    const body = { page: 1, page_size: 100, fields: "id,name", conditions: { status: ["ongoing","notStarted","ended"], keyword: "" } };
    const params = { platform: "learning-in-zju", path: "/api/my-courses", expected: "account-a" };
    assert.equal((await session.read({ ...params, body: JSON.stringify({ ...body, fields: "*" }) })).error, "unsafe");
    assert.equal((await session.read({ ...params, body: JSON.stringify(body) })).value, '{"courses":[],"total":0}');
    assert.equal(calls, 1);
});

test("a login HTML response is never treated as a task snapshot", async () => {
    const session = harness(moOrigin, async () => new Response("<html></html>", { headers: { "Content-Type": "text/html" } }));
    const result = await session.read({ platform: "mo", path: coursePath, body: null, expected: "account-a" });
    assert.equal(result.error, "invalid");
});
