from storages.backends.s3boto3 import S3Boto3Storage
import botocore.config
from boto3.s3.transfer import TransferConfig
import subprocess
import sys

class LinodeS3Boto3Storage(S3Boto3Storage):
    """
    Custom S3 storage backend for Linode Object Storage.
    Forces boto3 version 1.35.99 for compatibility.
    """
    
    def __init__(self, *args, **kwargs):
        # Ensure we're using boto3 1.35.99
        self._ensure_boto3_version()
        super().__init__(*args, **kwargs)
        # Set transfer config with very high multipart threshold
        self.transfer_config = TransferConfig(
            multipart_threshold=5 * 1024 * 1024 * 1024,  # 5 GB
            max_concurrency=1,
            use_threads=False,
        )
    
    def _ensure_boto3_version(self):
        """Ensure boto3 version 1.35.99 is installed"""
        try:
            import boto3
            if boto3.__version__ != '1.35.99':
                print(f"Installing boto3 1.35.99 (current: {boto3.__version__})")
                subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'boto3==1.35.99'])
                # Reload boto3 after installation
                import importlib
                import boto3
                importlib.reload(boto3)
        except Exception as e:
            print(f"Warning: Could not ensure boto3 version: {e}")
    
    def _get_client(self):
        session = botocore.session.get_session()
        client = session.create_client(
            's3',
            region_name=self.region_name,
            endpoint_url=self.endpoint_url,
            aws_access_key_id=self.access_key,
            aws_secret_access_key=self.secret_key,
            config=botocore.config.Config(
                s3={
                    'use_accelerate_endpoint': False,
                },
                retries={'max_attempts': 0},
                signature_version='s3v4'
            )
        )
        return client
