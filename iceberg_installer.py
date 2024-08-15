from collections import defaultdict
from ruamel.yaml import YAML

import json
import os
import sys
import subprocess
import re
import boto3

def validate_agent_config():
    yaml = YAML()
    with open("iceberg_agent.yaml") as agent_config_file:
        agent_config = yaml.load(agent_config_file)

    assert "catalog" in agent_config
    for k, v in agent_config["catalog"].items():
        assert "databases" in v

    for k, v in agent_config["catalog"].items():
        for db, dbv in v["databases"].items():
            for _db in dbv:
                for _k, _v in _db.items():
                    assert "uri" in _v

    print(f"Agent Config Validated: \n {json.dumps(agent_config, indent=4)}")


def get_target_s3_bucket_prefixes():
    yaml = YAML()
    target_s3_bucket_prefixes = {}

    with open("iceberg_agent.yaml") as agent_config_file:
        agent_config = yaml.load(agent_config_file)

    for k, v in agent_config["catalog"].items():
        for db, dbv in v["databases"].items():
            for _db in dbv:
                for _k, _v in _db.items():
                    target_s3_bucket_prefixes[_k] = _v["uri"]

    return target_s3_bucket_prefixes


def get_target_glue_database_tables():
    yaml = YAML()
    target_glue_database_tables = {}

    with open("iceberg_agent.yaml") as agent_config_file:
        agent_config = yaml.load(agent_config_file)

    for k, v in agent_config["catalog"].items():
        if k == "glue":
            for db, dbv in v["databases"].items():
                    for _db in dbv:
                        target_glue_database_tables[db] = [_k for _k, _ in _db.items()]

    return target_glue_database_tables

if __name__ == '__main__':
    validate_agent_config()
    target_buckets = list(set(get_target_s3_bucket_prefixes().values()))
    target_glue_database_tables = get_target_glue_database_tables()


    print(f"Installing lariat to S3 bucket prefixes {target_buckets}")

    lariat_api_key = os.environ.get("LARIAT_API_KEY")
    lariat_application_key = os.environ.get("LARIAT_APPLICATION_KEY")
    aws_region = os.environ.get("AWS_REGION")

    lariat_payload_source= os.environ.get("LARIAT_PAYLOAD_SOURCE", "s3")

    lariat_sink_aws_access_key_id = os.getenv("LARIAT_TMP_AWS_ACCESS_KEY_ID")
    lariat_sink_aws_secret_access_key = os.getenv("LARIAT_TMP_AWS_SECRET_ACCESS_KEY")

    tf_env = {
        "lariat_api_key": lariat_api_key,
        "lariat_application_key": lariat_application_key,
        "lariat_sink_aws_access_key_id": lariat_sink_aws_access_key_id,
        "lariat_sink_aws_secret_access_key": lariat_sink_aws_secret_access_key,
        "aws_region": aws_region,
        "target_s3_buckets": target_buckets,
        "target_glue_database_tables": target_glue_database_tables,
    }

    print("Passing configuration through to terraform")
    with open("lariat.auto.tfvars.json", "w") as f:
        json.dump(tf_env, f)
