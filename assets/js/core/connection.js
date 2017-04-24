(function() {
  Convos.Connection = function(attrs) {
    EventEmitter(this);
    this.connection_id = attrs.connection_id;
    this.name = attrs.name;
    this.me = {nick: ""};
    this.on_connect_commands = [];
    this.protocol = "unknown";
    this.state = "disconnected";
    this.user = attrs.user;
    this.wanted_state = attrs.wanted_state || "connected";
    this.url = "";
    this.on("message", this._onMessage);
    this.on("sent", this._onSent);
    this.on("state", this._onState);
  };

  var aliases = {};
  var proto = Convos.Connection.prototype;
  var msgId = 0;

  Convos.commands.forEach(function(cmd) {
    (cmd.aliases || [cmd.command]).forEach(function(a) {
      aliases[a] = cmd.alias_for ? cmd.alias_for : "/" + cmd.command;
    });
  });

  proto.addMessage = function(msg) {
    var dialog = msg.dialog_id ? this.getDialog(msg.dialog_id) : this.getDialog("");
    if (!dialog) dialog = this.user.activeDialog();
    if (!msg.dialog_id) msg.type = "private";
    if (!msg.from) msg.from = this.connection_id;
    if (dialog) return dialog.addMessage(msg);
    console.log("[Convos] Could not dispatch message from " + this.connection_id + ": ", msg);
  };

  proto.dialogs = function() {
    var id = this.connection_id;
    return this.user.dialogs.filter(function(d) { return d.connection_id == id; });
  };

  proto.getDialog = function(dialogId) {
    return this.user.dialogs.filter(function(d) {
      return d.connection_id == this.connection_id && d.dialog_id == dialogId;
    }.bind(this))[0];
  };

  proto.remove = function(cb) {
    var self = this;
    Convos.api.removeConnection({connection_id: this.connection_id}, function(err, xhr) {
      if (!err) {
        self.off("message").off("state");
        self.user.connections = self.user.connections.filter(function(c) {
          return c.connection_id != self.connection_id;
        });
        self.user.dialogs = self.user.dialogs.filter(function(d) {
          return d.connection_id != self.connection_id;
        });
      }
      cb.call(self, err);
    });
    return this;
  };

  proto.rooms = function(args, cb) {
    var self = this;

    Convos.api.roomsForConnection({connection_id: this.connection_id, match: args.match}, function(err, xhr) {
      cb.call(self, err, xhr.body);
    });

    return this;
  };

  proto.save = function(attrs, cb) {
    var self = this;
    var method = this.connection_id ? "updateConnection" : "createConnection";

    Convos.api[method]({body: attrs, connection_id: this.connection_id}, function(err, xhr) {
      if (err) return cb.call(self, err);
      cb.call(self.user.ensureConnection(xhr.body), err);
    });

    return this;
  };

  proto.send = function(message, dialog, cb) {
    var self = this;
    var action = message.match(/^\/(\w+)\s*(\S*)/) || ['', 'message', ''];
    var msg = {method: "send", id: ++msgId, connection_id: this.connection_id};
    var tid;

    if (aliases[action[1]]) {
      message = message.replace(/^\/(\w+)/, aliases[action[1]]);
      action = message.match(/^\/(\w+)\s*(\S*)/) || ['', 'message', ''];
    }

    if (!dialog) dialog = this.getDialog(action[2]); // action = ["...", "close", "#foo" ]
    if (!dialog) dialog = this.user.activeDialog();

    if (!cb) {
      tid = setTimeout(
        function() {
          msg.type = "error";
          msg.message = 'No response on "' + msg.message + '".';
          this.off("sent-" + msg.id);
          this.addMessage(msg);
        }.bind(this),
        5000
      );
      var handler = "_sent" + action[1].toLowerCase().ucFirst();
      cb = this[handler] || this._onError;
    }

    try {
      msg.connection_id = this.connection_id;
      msg.dialog_id = dialog ? dialog.dialog_id : "";
      msg.message = message;
      this.user.send(msg);
      this.once("sent-" + msg.id, cb); // Handle echo back from backend
      if (tid) this.once("sent-" + msg.id, function() { clearTimeout(tid) });
    } catch(e) {
      msg.type = "error";
      msg.message = e + " (" + message + ")";
      this.addMessage(msg);
      return;
    }

    return this;
  };

  proto.update = function(attrs) {
    Object.keys(attrs).forEach(function(n) { this[n] = attrs[n]; }.bind(this));

    if (attrs.hasOwnProperty("state")) {
        this.getDialog("").frozen = attrs.state == "connected" ? "" : "Not connected."
    }

    return this;
  };

  proto._onError = function(msg) {
    if (!msg.errors) return;
    this.user.ensureDialog(msg).addMessage({type: "error", message: msg.message + ": " + msg.errors[0].message});
  };

  proto._onMessage = function(msg) {
    if (msg.errors) return this._onError(msg);
    this.user.ensureDialog(msg).addMessage(msg);
  };

  proto._onSent = function(msg) {
    this.emit("sent-" + msg.id, msg).off("sent-" + msg.id);
  };

  proto._sentClose = function(msg) {
    if (msg.errors) return this._onError(msg);
    this.user.dialogs = this.user.dialogs.filter(function(d) {
      return d.connection_id != this.connection_id || d.dialog_id != msg.dialog_id;
    }.bind(this));
    Convos.settings.main = this.user.dialogs.length ? this.user.dialogs[0].href() : "";
  };

  proto._sentNames = function(msg) {
    if (msg.errors) return this._onError(msg);
    msg.type = "participants";
    this.addMessage(msg);
  };

  // part will not close the dialog
  proto._sentPart = function(msg) {
    if (msg.errors) return this._onError(msg);
    msg.type = "notice";
    msg.message = "You parted " + msg.dialog_id + ".";
    this.addMessage(msg);
  };

  proto._sentJoin = function(msg) {
    var dialog = this.user.ensureDialog(msg);
    Convos.settings.main = dialog.href();
  };

  proto._sentQuery = function(msg) {
    var dialog = this.user.ensureDialog(msg);
    Convos.settings.main = dialog.href();
  };

  proto._sentReconnect = function(msg) {
    this.addMessage({message: "Reconnecting..."});
  };

  proto._sentTopic = function(msg) {
    if (msg.errors) return this._onError(msg);
    msg.type = "notice";
    msg.message = msg.topic ? "Topic for " + dialog.name + " is: " + msg.topic : "There is no topic for " + dialog.name + ".";
    this.addMessage(msg);
  };

  proto._sentWhois = function(msg) {
    if (msg.errors) return this._onError(msg);
    msg.type = "whois";
    this.user.ensureDialog(msg).addMessage(msg);
  };

  proto._onState = function(data) {
    if (DEBUG.info) console.log("[state:" + data.type + "] " + this.connection_id + " = " + JSON.stringify(data));

    switch (data.type) {
      case "connection":
        var message = "Connection state changed to " + data.state;
        message += data.message ? ": " + data.message : ".";
        this.state = data.state;
        this.getDialog("").frozen = data.state == "connected" ? "" : data.message || data.state.ucFirst();
        this.addMessage({message: message});
        break;
      case "frozen":
        this.getDialog("").update({frozen: data.frozen});
        this.user.ensureDialog(data);
        break;
      case "join":
      case "part":
        this.dialogs().forEach(function(d) { d.participant(data); });
        break;
      case "me":
        if (this.me.nick && this.me.nick != data.nick) this.addMessage({message: "You changed nick to " + data.nick + "."});
        this.me.nick = data.nick;
        break;
      case "mode":
      case "nick_change":
      case "quit":
        this.dialogs().forEach(function(d) {
          data.dialog_id = d.dialog_id;
          d.participant(data);
        });
        break;
      case "topic":
        this.user.ensureDialog(data);
        break;
    }
  };
})();
