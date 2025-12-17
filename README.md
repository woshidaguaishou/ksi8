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







一、先手工建一个给 Flow Log 用的 IAM Role
1. 创建 IAM Role（空壳）

打开 IAM 控制台 → Roles（角色） → Create role

Trusted entity type（信任实体类型） 选：

Custom trust policy（自定义信任策略）

在 Custom trust policy 里粘下面这一段 JSON（官方文档也是这么写的）
AWS 文档
+1
：

{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "vpc-flow-logs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}



这个意思是：允许 VPC Flow Logs 服务 来扮演这个角色。
TGW Flow Logs 底层就是走 VPC Flow Logs，所以 principal 用的也是这个服务名。
AWS 文档
+1

点 Next。

2. 给这个 role 加 CloudWatch Logs 权限

在 Attach permissions 这一步：

可以直接点 Create policy（新建策略） → JSON，内容填这段（官方最小权限示例）：
AWS 文档
+1


{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "*"
    }
  ]
}



保存这个 Policy，例如叫：FlowLogs-To-CloudWatch。

