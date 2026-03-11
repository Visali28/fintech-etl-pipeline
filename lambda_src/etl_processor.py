import boto3, csv, os, re, random
from datetime import datetime

s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
sqs = boto3.client('sqs')

DLQ_URL = os.environ['DLQ_URL']
TABLE_NAME = os.environ['TABLE_NAME']

def mask_pan(pan): return pan[:3] + "*****" + pan[-1]
def mask_aadhaar(aadhaar): return "********" + aadhaar[-4:]

def validate(record):
    if not record['txn_id']: return False, "Empty txn_id"
    if float(record['amount']) < 0: return False, "Negative amount"
    if not re.match(r'^[A-Z]{5}[0-9]{4}[A-Z]$', record['pan']): return False, "Invalid PAN"
    if not re.match(r'^\d{12}$', record['aadhaar']): return False, "Invalid Aadhaar"
    return True, None

def lambda_handler(event, context):
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = event['Records'][0]['s3']['object']['key']
    obj = s3.get_object(Bucket=bucket, Key=key)
    rows = obj['Body'].read().decode('utf-8').splitlines()
    reader = csv.DictReader(rows)

    table = dynamodb.Table(TABLE_NAME)
    failures, processed = 0, 0

    for row in reader:
        valid, reason = validate(row)
        if not valid:
            sqs.send_message(QueueUrl=DLQ_URL, MessageBody=str({"record": row, "reason": reason}))
            failures += 1
            continue

        row['pan'] = mask_pan(row['pan'])
        row['aadhaar'] = mask_aadhaar(row['aadhaar'])
        row['processed_timestamp'] = datetime.utcnow().isoformat()
        row['risk_score'] = random.randint(1,5)
        row['valid_txn'] = True

        table.put_item(Item=row)
        processed += 1

    print(f"File: {key}, Processed: {processed}, Failures: {failures}")

