package.path = "./?.lua;./?/init.lua;" .. package.path
local Embeds = require("src.discord.embeds")
local Response = require("src.discord.response")

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then io.stdout:write("ok - " .. name .. "\n")
  else failed = failed + 1; io.stderr:write("not ok - " .. name .. ": " .. tostring(err) .. "\n") end
end
local function equal(actual, expected)
  assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

test("embed palette and core response categories are centralized", function()
  equal(Embeds.palette.primary_pink, 0xF8BBD0)
  equal(Embeds.palette.soft_rose, 0xF48FB1)
  equal(Embeds.palette.lavender, 0xD8B4FE)
  equal(Embeds.palette.cream, 0xFFF1F5)
  equal(Embeds.palette.error_rose, 0xE57373)
  for _, kind in ipairs({ "success", "error", "warning", "info", "moderation", "economy", "music", "voice", "system" }) do
    local embed = Embeds.create(kind, "Test", "Details")
    assert(embed.color == Embeds.colors[kind])
    equal(embed.description, "Details")
    equal(embed.author.name, "KiddyyMolly 🎀")
    assert(embed.footer.text:find("KiddyyMolly", 1, true))
  end
end)

test("about command renders verified features, build version, and the brand disclaimer", function()
  local Router = require("src.commands.router")
  local Smoke = require("src.commands.smoke")
  local router, called = Router.new(), nil
  Smoke.register(router, {}, { version = "1.2-test" })
  local ctx = { respond = function(_, content, options) called = { content = content, options = options }; return true end }
  ctx._molly_category, ctx._molly_command_name = "Information", "about"
  Response.decorate(ctx)
  assert(router:dispatch("about", ctx))
  assert(called and called.content == nil and #called.options.embeds == 1)
  local embed = called.options.embeds[1]
  equal(embed.title, "KiddyyMolly 🎀")
  equal(embed.color, Embeds.palette.primary_pink)
  assert(embed.description:find("I'm KiddyyMolly, your pink little Discord bestie", 1, true))
  local fields = {}
  for _, field in ipairs(embed.fields) do fields[field.name] = field.value end
  assert(fields["Molly Coins & shopping 💗"]:find("fictional", 1, true))
  assert(fields["Molly Coins & shopping 💗"]:find("not affiliated", 1, true))
  assert(fields["Version & runtime 🛠️"]:find("1.2-test", 1, true))
  assert(fields["Project 📎"]:find("AGPL-3.0", 1, true))
  assert(#embed.fields <= 25 and #embed.title <= 256 and #embed.description <= 4096)
  local aggregate = #embed.title + #embed.description + #embed.author.name + #embed.footer.text
  for _, field in ipairs(embed.fields) do
    assert(#field.name <= 256 and #field.value <= 1024)
    aggregate = aggregate + #field.name + #field.value
  end
  assert(aggregate <= 6000)
end)

test("shop, inventory, and economy responses use readable Molly titles", function()
  equal(Embeds.for_command("Economy", "shop", "Shop contents")[1].title, "KiddyyMolly's Virtual Shop 🛍️")
  equal(Embeds.for_command("Economy", "inventory", "Your items")[1].title, "Your Molly Closet 🎀")
  equal(Embeds.for_command("Economy", "balance", "Wallet: 12 coins")[1].title, "Molly Coins 💗")
end)

test("help keeps registered command grouping and accurate virtual shop wording", function()
  local Router = require("src.commands.router")
  local Information = require("src.commands.information")
  local router, called = Router.new(), nil
  router:register({ name = "daily", category = "Economy", description = "Claim a daily reward", execute = function() end })
  Information.register(router, {})
  local ctx = { respond = function(_, content, options) called = { content = content, options = options }; return true end }
  ctx._molly_category, ctx._molly_command_name = "Utility", "help"
  Response.decorate(ctx)
  assert(router:dispatch("help", ctx))
  local description = called.options.embeds[1].description
  assert(description:find("/daily", 1, true))
  assert(description:find("Sephora virtual looks are free", 1, true))
  assert(description:find("not affiliated", 1, true))
end)

test("command output gets a category embed and readable severity", function()
  local success = Embeds.for_command("Music", "play", "Added **A Song** to the queue.")[1]
  equal(success.color, Embeds.colors.success)
  equal(success.description, "Added **A Song** to the queue.")
  local error_embed = Embeds.for_command("Economy", "pay", "Insufficient funds.")[1]
  equal(error_embed.color, Embeds.colors.error)
  local info = Embeds.for_command("Information", "about", "Molly is here.")[1]
  equal(info.color, Embeds.colors.info)
end)

test("health output is represented as fields without changing its values", function()
  local embeds = Embeds.for_command("Utility", "health", table.concat({
    "Molly Health — Healthy", "Process: Healthy", "Runtime: Healthy", "Discord: Healthy",
    "SeaWorld: Healthy (API 1.0.0)", "Persistence: Healthy", "Music: connected", "Uptime: 2h 14m",
  }, "\n"))
  equal(#embeds, 1)
  equal(embeds[1].title, "Molly Health — Healthy")
  equal(#embeds[1].fields, 7)
  equal(embeds[1].fields[4].value, "Healthy (API 1.0.0)")
end)

test("ping and health commands keep their values in central system embeds", function()
  local ping = Embeds.for_command("Utility", "ping", "🏓 Pong! 42 ms")[1]
  equal(ping.title, "Pong")
  equal(ping.description, "🏓 Pong! 42 ms")
  local health = Embeds.for_command("Utility", "health", "Molly Health — Healthy\nDiscord: Healthy")[1]
  equal(health.title, "Molly Health — Healthy")
  equal(health.fields[1].value, "Healthy")
end)

test("long command text respects description and aggregate Discord embed limits", function()
  local embeds = Embeds.for_command("Utility", "help", string.rep("Useful command information.\n", 400))
  assert(#embeds <= 2)
  local aggregate = 0
  for _, embed in ipairs(embeds) do
    assert(#(embed.description or "") <= 4096)
    aggregate = aggregate + #(embed.title or "") + #(embed.description or "") + #(embed.footer.text or "") + #(embed.author.name or "")
  end
  assert(aggregate <= 6000)
  assert(embeds[#embeds].description:find("shortened to fit", 1, true))
end)

test("automatic response embeds preserve ephemeral flags and components", function()
  local called
  local ctx = { respond = function(_, content, options) called = { content = content, options = options }; return true end }
  ctx._molly_category, ctx._molly_command_name = "Moderation", "warn"
  Response.decorate(ctx)
  ctx:respond("You do not have permission to use this command.", { ephemeral = true, components = { "kept" } })
  equal(called.content, nil)
  equal(called.options.ephemeral, true)
  equal(called.options.components[1], "kept")
  equal(called.options.embeds[1].color, Embeds.colors.error)
  equal(called.options.embeds[1].description, "You do not have permission to use this command.")
end)

test("response presentation stays branded while sensitive and technical wording stays exact", function()
  local cases = {
    { "Moderation", "warn", "Warning saved for user 123456789012345678; case C42." },
    { "Administration", "settings", "You do not have permission to change server settings." },
    { "Utility", "runtime", "Molly Health: Status degraded · SeaWorld unavailable" },
  }
  for _, case in ipairs(cases) do
    local embed = Embeds.for_command(case[1], case[2], case[3])[1]
    equal(embed.description, case[3])
    equal(embed.author.name, "KiddyyMolly 🎀")
    assert(embed.footer.text:find("KiddyyMolly", 1, true))
  end
end)

test("ordinary decorated command responses remain public embeds", function()
  local called
  local ctx = { respond = function(_, content, options) called = { content = content, options = options }; return true end }
  ctx._molly_category, ctx._molly_command_name = "Information", "about"
  Response.decorate(ctx)
  ctx:respond("Molly is your moderation assistant.")
  equal(called.content, nil)
  assert(called.options.ephemeral == nil)
  assert(called.options.embeds[1] and called.options.embeds[1].description == "Molly is your moderation assistant.")
end)

test("deferred edits and explicit music embeds use the installed response shape", function()
  local called
  local ctx = { edit = function(_, content, options) called = { content = content, options = options }; return true end }
  ctx._molly_category, ctx._molly_command_name = "Music", "nowplaying"
  Response.decorate(ctx)
  Response.set_embed(ctx, { kind = "music", title = "Track", description = "Now playing the track.",
    fields = { { name = "Artist", value = "Artist Name", inline = true } }, thumbnail = "https://example.test/art.png" })
  ctx:edit("Now playing the track.")
  equal(called.content, nil)
  equal(called.options.embeds[1].title, "Track")
  equal(called.options.embeds[1].fields[1].value, "Artist Name")
  equal(called.options.embeds[1].thumbnail.url, "https://example.test/art.png")
end)

test("existing component embeds remain intact and text component replies are decorated", function()
  local calls = {}
  local ctx = {
    update = function(_, content, options) calls.update = { content = content, options = options }; return true end,
    respond = function(_, content, options) calls.respond = { content = content, options = options }; return true end,
  }
  ctx._molly_category, ctx._molly_command_name = "Music", "music-panel"
  Response.decorate(ctx)
  local existing = { title = "Already structured" }
  ctx:update(nil, { embeds = { existing }, components = { "buttons" } })
  equal(calls.update.options.embeds[1], existing)
  ctx:respond("The queue is empty.", { ephemeral = true })
  equal(calls.respond.content, nil)
  equal(calls.respond.options.ephemeral, true)
  assert(calls.respond.options.embeds[1])
end)

io.stdout:write(string.format("%d tests, %d failures\n", total, failed))
os.exit(failed == 0 and 0 or 1)
