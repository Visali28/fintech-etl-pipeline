import boto3, os, ast
from datetime import datetime

sqs = boto3.client('sqs')
dynamodb = boto3.resource('dynamodb')

DLQ_URL = os.environ['DLQ_URL']
TABLE_NAME = os.environ['TABLE_NAME']

def lambda_handler(event, context):
    table = dynamodb.Table(TABLE_NAME)
    msgs = sqs.receive_message(QueueUrl=DLQ_URL, MaxNumberOfMessages=10, WaitTimeSeconds=2)

    if 'Messages' not in msgs:
        print("No messages to replay")
        return

    for m in msgs['Messages']:
        body = ast.literal_eval(m['Body'])
        record = body['record']
        try:
            record['processed_timestamp'] = datetime.utcnow().isoformat()
            record['risk_score'] = 3
            record['valid_txn'] = True
            table.put_item(Item=record)
            sqs.delete_message(QueueUrl=DLQ_URL, ReceiptHandle=m['ReceiptHandle'])
            print(f"Reprocessed txn_id={record['txn_id']}")
        except Exception as e:
            print(f"Replay failed: {e}")

