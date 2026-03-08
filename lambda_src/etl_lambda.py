import json
import boto3
import csv
import re
import random
from datetime import datetime

s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
sqs = boto3.client('sqs')

TABLE = dynamodb.Table('fintech-transactions')
DLQ_URL = "PASTE_DLQ_URL_HERE"

PAN_REGEX = r'^[A-Z]{5}[0-9]{4}[A-Z]$'

def mask_pan(pan):
    return pan[:3] + "*****" + pan[-1]

def mask_aadhaar(aadhaar):
    return "********" + aadhaar[-4:]

def validate(row):

    if not row['txn_id']:
        return False, "Missing txn_id"

    if float(row['amount']) < 0:
        return False, "Negative amount"

    if not re.match(PAN_REGEX, row['pan']):
        return False, "Invalid PAN"

    if not (row['aadhaar'].isdigit() and len(row['aadhaar']) == 12):
        return False, "Invalid Aadhaar"

    return True, "Valid"

def lambda_handler(event, context):

    failures = 0
    processed = 0

    for record in event['Records']:

        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']

        obj = s3.get_object(Bucket=bucket, Key=key)
        rows = csv.DictReader(obj['Body'].read().decode().splitlines())

        for row in rows:

            valid, reason = validate(row)

            if not valid:

                sqs.send_message(
                    QueueUrl=DLQ_URL,
                    MessageBody=json.dumps({
                        "record": row,
                        "reason": reason
                    })
                )

                failures += 1
                continue

            TABLE.put_item(
                Item={
                    "txn_id": row['txn_id'],
                    "customer_id": row['customer_id'],
                    "amount": float(row['amount']),
                    "pan": mask_pan(row['pan']),
                    "aadhaar": mask_aadhaar(row['aadhaar']),
                    "processed_timestamp": datetime.utcnow().isoformat(),
                    "risk_score": random.randint(1,5),
                    "valid_txn": True
                }
            )

            processed += 1

    print("Processed:", processed)
    print("Failures:", failures)

    return {"processed": processed, "failures": failures}
