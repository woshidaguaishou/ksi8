ALB_BASE_URL=http://ALB-448078466.ap-northeast-1.elb.amazonaws.com
import os
import urllib.request
import urllib.error

ALB_BASE_URL = os.environ["ALB_BASE_URL"].rstrip("/")


def lambda_handler(event, context):
    # HTTP API v2 的事件结构
    raw_path = event.get("rawPath", "/")
    raw_query = event.get("rawQueryString", "")

    # 拼接要请求的 URL
    url = ALB_BASE_URL + (raw_path or "/")
    if raw_query:
        url += "?" + raw_query

    try:
        # 简单只转发 GET，如果你要支持 POST/PUT，可以再扩展
        req = urllib.request.Request(url, method="GET")

        # 把 User-Agent 之类加一点也行（可选）
        req.add_header("User-Agent", "Lambda-ALB-Proxy")

        with urllib.request.urlopen(req, timeout=10) as resp:
            body_bytes = resp.read()
            status = resp.getcode()
            headers = dict(resp.getheaders())

        # 简单处理一下 Content-Type，默认 text/html
        content_type = headers.get("Content-Type", "text/html; charset=utf-8")

        # Lambda 要求 body 是字符串，这里假设后端返回的是 UTF-8 HTML
        body_str = body_bytes.decode("utf-8", errors="replace")

        return {
            "statusCode": status,
            "headers": {
                "Content-Type": content_type
            },
            "body": body_str
        }

    except urllib.error.HTTPError as e:
        # 后端返回 4xx/5xx 时
        err_body = e.read().decode("utf-8", errors="replace")
        return {
            "statusCode": e.code,
            "headers": {
                "Content-Type": "text/html; charset=utf-8"
            },
            "body": err_body
        }
    except Exception as e:
        # 其他错误
        return {
            "statusCode": 502,
            "headers": {
                "Content-Type": "text/plain; charset=utf-8"
            },
            "body": f"Lambda error: {str(e)}"
        }


