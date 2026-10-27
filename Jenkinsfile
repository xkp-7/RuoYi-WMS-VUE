pipeline {
    agent any

    tools {
        nodejs 'Node26' // 对应“全局工具配置”中的 NodeJS 别名
    }

    environment {
        // 远程服务器信息（建议移至参数或凭据）
        REMOTE_USER = 'root'
        REMOTE_HOST = '192.168.9.228' // 远程服务器 IP
        REMOTE_BASE = '/data/apps/ruoyi-vue/incoming' // 上传区，web root 之外
        APP_NAME = 'dist.tar.gz'
        DEPLOY_NAME = 'deploy.sh'
        DEPLOY_COMMAND = 'bash deploy.sh deploy'
        // 在 Jenkins 中创建的 SSH 凭据 ID
        SSH_CRED_ID = 'jenkins_ssh'
        //镜像源
        NPM_CONFIG_REGISTRY = 'https://registry.npmmirror.com'
    }

    stages {
        stage('检出代码') {
            steps {
                checkout scm
            }
        }

        stage('安装依赖') {
            steps {
                sh 'npm install' 
            }
        }

        stage('构建') {
            steps {
                sh 'npm run build:prod'
            }
        }

        stage('产物校验') {
            steps {
                // 简单的完整性检查，尽早发现构建异常
                sh 'ls -la dist/'
                sh 'test -f dist/index.html || (echo "dist/index.html 不存在，构建失败" && exit 1)'
            }
        }

        stage('打包') {
            steps {
                sh "tar -czf ${APP_NAME} dist/"
            }
        }


        stage('部署') {
            steps {
                sshagent(credentials: [SSH_CRED_ID]) {
                    // 1. 确保远程目录存在
                    sh """
                        ssh -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST} \
                        "mkdir -p ${REMOTE_BASE}"
                    """

                    // 2. 上传 tar 包 和 脚本
                    sh """
                        scp -o StrictHostKeyChecking=no \
                        ${APP_NAME} \
                        ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE}/

                        scp -o StrictHostKeyChecking=no \
                        ${DEPLOY_NAME} \
                        ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE}/
                    """


                    // 4. 远程执行重启脚本
                    sh """
                        ssh -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST} \
                        'cd ${REMOTE_BASE} && ${DEPLOY_COMMAND} && echo "Deployment complete."'
                    """
                }
            }
        }
    }

}
