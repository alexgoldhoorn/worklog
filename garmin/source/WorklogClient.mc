import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;

typedef ClientDone as Method(ok as Boolean, result as Dictionary or String) as Void;

//! Calls the worklog JSON API through the phone. One request at a time per instance.
(:glance)
class WorklogClient {
    private var _done as ClientDone or Null;

    function initialize() {
        _done = null;
    }

    //! action: :status (GET /api/status) or :start, :pause, :stop (POST /api/<name>).
    //! Settings are read on every call, so a change in the phone app applies at once.
    function call(action as Symbol, body as Dictionary or Null, done as ClientDone) as Void {
        var url = prop("serverUrl");
        var user = prop("user");
        var password = prop("password");
        if (!Logic.hasLogin(url, user, password)) {
            done.invoke(false, "No login");
            return;
        }
        _done = done;
        var name = "status";
        if (action == :start) {
            name = "start";
        } else if (action == :pause) {
            name = "pause";
        } else if (action == :stop) {
            name = "stop";
        }
        var get = action == :status;
        var options = {
            :method => get ? Communications.HTTP_REQUEST_METHOD_GET : Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {
                "Authorization" => Logic.basicAuth(user, password),
                "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Communications.makeWebRequest(Logic.baseUrl(url) + "/api/" + name + "?brief=1",
            get ? null : (body == null ? {} : body), options, method(:onReceive));
    }

    function onReceive(code as Number, data as Dictionary or String or Null) as Void {
        var done = _done;
        _done = null;
        if (done == null) {
            return;
        }
        if (code == 200 && data instanceof Dictionary) {
            done.invoke(true, data);
        } else {
            done.invoke(false, Logic.errorText(code, data));
        }
    }

    private function prop(key as String) as String {
        var v = Application.Properties.getValue(key);
        return v instanceof String ? v : "";
    }
}
